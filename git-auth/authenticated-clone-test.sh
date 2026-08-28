#!/usr/bin/env bash
#
# authenticated-clone-test.sh — contract suite for git-auth/, i.e. for how
# `clone-repo` and `clone-siblings` hand a CI GitHub token to git.
#
# WHY THESE ASSERTIONS AND NOT CHEAPER ONES
# -----------------------------------------
# The cheap way to test a git credential is to ask git's own matchers what they
# would do: `git config --get-urlmatch`, `git ls-remote --get-url`. That is what
# `setup-nix/configure-git-auth-test.sh` does, correctly, because the thing it
# guards IS a piece of configuration.
#
# It is not enough here, and the reason is on the record: the first version of
# that suite passed unchanged against the unfixed action, because
# `--get-urlmatch` cannot see a credential smuggled into a URL. Right answer,
# wrong reason. The defect this suite guards has exactly that shape — a token
# inside `https://x-access-token:...@github.com/...` — so asking a matcher would
# reproduce the same false pass.
#
# So this suite does not ask. It stands up a REAL git server over HTTP
# (`git http-backend`, the CGI that ships with git, behind
# ./git-http-auth-server.py), serves real repositories from it, requires HTTP
# Basic authentication on one owner's path prefix and not another's, and makes
# the real `authenticated-clone.sh` clone through it. The server journals, per
# request, whether a credential arrived and whether it matched. The assertions
# read that journal and the resulting clone on disk. Both directions —
# "authentication still works" and "the credential is nowhere it should not be" —
# are observed rather than modelled.
#
# MUTATION-VERIFIED. Several assertions are paired with a deliberate
# reproduction of the code they replaced (`legacy_clone`, the shape on `main`:
# a token in the clone URL plus a catch-all `insteadOf` in the clone's own
# `.git/config`). The suite asserts the detector fires on that shape and stays
# quiet on the new one. An assertion nobody has ever seen fail is a comment.
#
# NO MOCKS. Real git, real HTTP, real submodules, real nested submodules. The
# only synthetic thing is the token, which is a constant that is not a
# credential to anything — the same convention `configure-git-auth-test.sh`
# already uses. Nothing in this suite prints it.
#
# Run: bash git-auth/authenticated-clone-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/scoped-git-auth.sh"
CLONE="$HERE/authenticated-clone.sh"
SERVER="$HERE/git-http-auth-server.py"

for f in "$LIB" "$CLONE" "$SERVER"; do
	[[ -f $f ]] || {
		echo "authenticated-clone-test: cannot find $f" >&2
		exit 2
	}
done

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL $1"
	[[ -n ${2:-} ]] && echo "     $2"
}
check() { # <desc> <actual> <expected>
	if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}
assert() { # <desc> <0/1>
	if [[ $2 == 0 ]]; then ok "$1"; else bad "$1"; fi
}

TMPROOT="$(mktemp -d)"
SRV_PID=""
cleanup() {
	# By PID, recorded when this suite started it. Never by name pattern: this
	# repo's suites run on shared self-hosted runners carrying other people's
	# jobs, and a `pkill -f python3` would take them with it.
	[[ -n $SRV_PID ]] && kill "$SRV_PID" 2>/dev/null
	rm -rf "$TMPROOT"
}
trap cleanup EXIT

# A constant shaped like a GitHub App installation token so a substring search
# for it cannot match ordinary text. It authenticates nothing.
TOKEN="ghs_TESTONLYnotarealtoken0000000000000000"
printf '%s' "$TOKEN" >"$TMPROOT/token"

# ---------------------------------------------------------------------------
# Fixtures: four repositories, two of them reachable only through a submodule.
#
# This is the codetracer shape on purpose, because preserving it is a hard
# requirement: `codetracer` has a PRIVATE submodule (`libs/tree-sitter-nim`)
# inside a public repository, and `codetracer-native-backend` clones and then
# recurses into a private `codetracer-rr`. Both spellings that appear in this
# org's `.gitmodules` files are exercised — scp-style `git@github.com:` at the
# first level and `ssh://git@github.com/` at the second — because the ssh
# spellings are the ones that only work if the credential-free `insteadOf`
# rewrites travel with the credential.
# ---------------------------------------------------------------------------
SRV="$TMPROOT/srv"
mkdir -p "$SRV/metacraft-labs" "$SRV/third-party"

git_q() { git "$@" >/dev/null 2>&1; }

# `mk_repo <bare> [<gitmodules-content> <submodule-path> <submodule-sha>]`
mk_repo() {
	local bare="$1" gm="${2:-}" sub_path="${3:-}" sub_sha="${4:-}"
	local work="$TMPROOT/build/${bare//\//_}"
	git_q init --bare -b main "$SRV/$bare"
	mkdir -p "$work"
	git_q -C "$work" init -b main .
	printf 'content of %s\n' "$bare" >"$work/README"
	git_q -C "$work" add README
	if [[ -n $gm ]]; then
		printf '%s' "$gm" >"$work/.gitmodules"
		git_q -C "$work" add .gitmodules
		# A gitlink cannot be created by `submodule add` here: the URL in
		# `.gitmodules` is a github.com URL that does not exist. Write the index
		# entry directly, which is what a gitlink is.
		git -C "$work" update-index --add --cacheinfo "160000,$sub_sha,$sub_path" >/dev/null 2>&1
	fi
	git -C "$work" -c user.name=t -c user.email=t@t commit -qm init >/dev/null 2>&1
	git_q -C "$work" push "$SRV/$bare" main
	git -C "$work" rev-parse HEAD
}

DEEP_SHA="$(mk_repo metacraft-labs/deep.git)"
TSN_SHA="$(mk_repo metacraft-labs/tree-sitter-nim.git \
	'[submodule "deep"]
	path = deep
	url = ssh://git@github.com/metacraft-labs/deep.git
' deep "$DEEP_SHA")"
HOST_SHA="$(mk_repo metacraft-labs/host.git \
	'[submodule "libs/tree-sitter-nim"]
	path = libs/tree-sitter-nim
	url = git@github.com:metacraft-labs/tree-sitter-nim.git
' libs/tree-sitter-nim "$TSN_SHA")"
THIRD_SHA="$(mk_repo third-party/dep.git)"

# ---------------------------------------------------------------------------
# The server. `/metacraft-labs/` requires the credential; `/third-party/` does
# not, and journals whether one turned up anyway.
# ---------------------------------------------------------------------------
JOURNAL="$TMPROOT/journal"
python3 "$SERVER" --root "$SRV" --journal "$JOURNAL" \
	--auth-prefix /metacraft-labs/ --auth-file "$TMPROOT/token" \
	>"$TMPROOT/port" 2>"$TMPROOT/server.err" &
SRV_PID=$!
for _ in $(seq 1 100); do
	[[ -s $TMPROOT/port ]] && break
	sleep 0.1
done
PORT="$(while IFS=' ' read -r _tag _p; do printf '%s' "$_p"; done <"$TMPROOT/port")"
[[ -n $PORT ]] || {
	echo "authenticated-clone-test: server did not start" >&2
	cat "$TMPROOT/server.err" >&2
	exit 2
}
BASE="http://127.0.0.1:${PORT}/"

journal_verdicts() { # <path-substring> -> the verdicts recorded for it
	local want="$1" v p
	while read -r v p; do
		case "$p" in *"$want"*) printf '%s\n' "$v" ;; esac
	done <"$JOURNAL"
}

# ---------------------------------------------------------------------------
# `credential_files <dir>` — an INDEPENDENT search for the credential on disk.
#
# Deliberately not the walker inside authenticated-clone.sh: a check that shares
# its implementation with the thing it checks agrees with it by construction,
# including about what it forgot to look at. This one greps the whole tree,
# working files and git objects alike, and reports only file names.
# ---------------------------------------------------------------------------
credential_files() {
	local dir="$1"
	[[ -d $dir ]] || return 0
	grep -rlF "$TOKEN" "$dir" 2>/dev/null
	grep -rlF "x-access-token" "$dir" 2>/dev/null
}

# A sandbox HOME with a `credential.helper`, and system/global config
# neutralised. Both halves are load-bearing, and the second one was found the
# hard way.
#
# WHY A SANDBOX HOME. Running these clones against the developer's real HOME
# lets the machine answer for the code. It is not hypothetical: the first run of
# this suite passed a negative contract for the wrong reason because a globally
# configured `credential.helper = store` had captured the credential from the
# EARLIER `legacy_clone` (a URL carries userinfo, git calls `credential approve`
# on success, the helper writes it to `~/.git-credentials`) and then handed it
# back for a later clone that was supposed to be unauthenticated. That is the
# same class of contamination that made `configure-git-auth-test.sh`'s first CI
# run answer from the checkout's own header. It also means the suite had written
# its token into the developer's credential store, which is the sort of thing a
# test fixture must never do to the machine it runs on.
#
# WHY A HELPER IS CONFIGURED IN THE SANDBOX ANYWAY. Because that capture is a
# real, unlisted property of the shape being removed — a FOURTH place the old
# code persisted the token, alongside the clone URL, the `.git/config` and the
# submodule `.git/config`s — and it is worth an assertion of its own (below).
#
# The legacy mutation gets a SEPARATE sandbox. Once it runs, the helper holds a
# credential for the test server, and every later "this must be unauthenticated"
# assertion would answer from the store instead of from the code — which is the
# exact failure this isolation exists to prevent, reintroduced by the fixture.
SANDBOX="$TMPROOT/home"
SANDBOX_LEGACY="$TMPROOT/home-legacy"
mkdir -p "$SANDBOX" "$SANDBOX_LEGACY"
git config --file "$SANDBOX/.gitconfig" credential.helper store
git config --file "$SANDBOX_LEGACY/.gitconfig" credential.helper store

# `sandboxed <cmd...>` — run with the machine's git configuration out of the
# way. The system config is neutralised; the sandbox's own `~/.gitconfig` is
# still read, because that is where the helper under test lives.
sandboxed() {
	env HOME="$SANDBOX" GIT_CONFIG_SYSTEM=/dev/null GIT_CEILING_DIRECTORIES="$TMPROOT" "$@"
}
sandboxed_legacy() {
	env HOME="$SANDBOX_LEGACY" GIT_CONFIG_SYSTEM=/dev/null GIT_CEILING_DIRECTORIES="$TMPROOT" "$@"
}

# `run_clone <name> <args...>` — the real thing: derive the scope with the real
# library, export it into the process, run the real clone script. Exactly what
# clone-repo/action.yml and clone-siblings/action.yml do.
run_clone() {
	local name="$1"
	shift
	CASE_OUT="$TMPROOT/$name.out"
	CASE_RC=0
	sandboxed \
		GH_TOKEN="$TOKEN" \
		GIT_AUTH_URL_BASE="$BASE" \
		TOKEN_OWNERS="${CASE_OWNERS:-metacraft-labs}" \
		SCOPED_GIT_AUTH_REWRITES=1 \
		bash -c '
			set -euo pipefail
			. "$1"; shift
			scoped_git_auth_build
			scoped_git_auth_export
			exec bash "$@"
		' _ "$LIB" "$CLONE" "$@" >"$CASE_OUT" 2>&1 || CASE_RC=$?
}

# `legacy_clone <repo> <dest>` — the shape on `main`, reproduced so the
# detectors above can be shown to fire on it. This is the mutation.
legacy_clone() {
	local repo="$1" dest="$2"
	local tok="${BASE%%//*}//x-access-token:${TOKEN}@${BASE#*//}"
	rm -rf "$dest"
	sandboxed_legacy git clone --quiet --no-checkout "${tok}${repo}.git" "$dest" >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" fetch --quiet --depth 1 origin main >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" config --add url."$tok".insteadOf "${BASE}" >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" config --add url."$tok".insteadOf "git@github.com:" >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" config --add url."$tok".insteadOf "ssh://git@github.com/" >/dev/null 2>&1
	sandboxed_legacy git -C "$dest" submodule update --init --recursive >/dev/null 2>&1
}

# ===========================================================================
# 1. The private clone, with submodules, at two levels of nesting.
# ===========================================================================
run_clone host --repo metacraft-labs/host --dest "$TMPROOT/host" \
	--rev "$HOST_SHA" --shallow --submodules

check "a private repo clones through the scoped header" "$CASE_RC" "0"
check "the private repo's content is there" \
	"$([[ -f $TMPROOT/host/README ]] && echo yes)" "yes"
check "a private scp-style submodule is checked out (codetracer libs/tree-sitter-nim)" \
	"$([[ -f $TMPROOT/host/libs/tree-sitter-nim/README ]] && echo yes)" "yes"
check "a private ssh:// NESTED submodule is checked out (native-backend -> rr)" \
	"$([[ -f $TMPROOT/host/libs/tree-sitter-nim/deep/README ]] && echo yes)" "yes"

# The wire, not the configuration: the server says a credential arrived and
# matched, for the superproject and for both submodules.
for repo in host tree-sitter-nim deep; do
	V="$(journal_verdicts "/metacraft-labs/${repo}.git/info/refs")"
	case "$V" in
	*ok*) ok "the server received a matching credential for ${repo}" ;;
	*) bad "the server received a matching credential for ${repo}" "journal said: ${V:-<nothing>}" ;;
	esac
	case "$V" in
	*none* | *mismatch*) bad "no unauthenticated attempt was made for ${repo}" "journal said: $V" ;;
	*) ok "no unauthenticated attempt was made for ${repo}" ;;
	esac
done

# ===========================================================================
# 2. Nothing was written down. This is the defect.
# ===========================================================================
FOUND="$(credential_files "$TMPROOT/host" | while IFS= read -r f; do printf '%s ' "${f#"$TMPROOT/host/"}"; done)"
check "no credential anywhere under the clone, submodules included" "$FOUND" ""

check ".git/config records a credential-free remote" \
	"$(git -C "$TMPROOT/host" config --get remote.origin.url)" \
	"${BASE}metacraft-labs/host.git"
check "no url.*.insteadOf was written into the clone at all" \
	"$({ git -C "$TMPROOT/host" config --local --name-only --get-regexp '^url\.' 2>/dev/null || true; } | grep -c . || true)" "0"
check "no extraheader was written into the clone" \
	"$({ git -C "$TMPROOT/host" config --local --name-only --get-regexp '^http\..*extraheader$' 2>/dev/null || true; } | grep -c . || true)" "0"

# The FOURTH persistence channel, which neither the `setup-nix` change nor its
# rationale names: a credential carried in a URL is one git hands to `credential
# approve` after a successful fetch, so on any runner with a `credential.helper`
# — and this org's runners reuse $HOME — the old shape additionally wrote the
# App token into `~/.git-credentials`, where it survives the job under a name
# nobody greps for. `setup-nix` deliberately does not reset `credential.helper`
# (doing so would break consumers that authenticate through `gh auth
# setup-git`), so this is mitigated nowhere else; it is fixed only by keeping the
# credential out of the URL, which is what this change does.
#
# The sandbox HOME has `credential.helper = store` configured precisely so this
# is observable. It must be asserted BEFORE the mutation below, which is what
# makes it happen.
check "nothing was captured into ~/.git-credentials by a helper" \
	"$([[ -f $SANDBOX/.git-credentials ]] && grep -cF "$TOKEN" "$SANDBOX/.git-credentials" || echo 0)" "0"

# MUTATION. Same server, same repos, the shape this change removes. If the
# search above cannot tell the two apart, it is not testing anything.
legacy_clone metacraft-labs/host "$TMPROOT/legacy"

if [[ -f $SANDBOX_LEGACY/.git-credentials ]] && grep -qF "$TOKEN" "$SANDBOX_LEGACY/.git-credentials"; then
	ok "mutation: the URL shape DOES get captured by a credential helper"
else
	bad "mutation: the URL shape DOES get captured by a credential helper" \
		"nothing was stored, so the assertion above proves nothing"
fi
LEGACY_FOUND="$(credential_files "$TMPROOT/legacy" | grep -c . || true)"
if [[ $LEGACY_FOUND -gt 0 ]]; then
	ok "mutation: the same search DOES find the credential in the shape this replaces ($LEGACY_FOUND file(s))"
else
	bad "mutation: the same search DOES find the credential in the shape this replaces" \
		"it found nothing, so the assertion above proves nothing"
fi
check "mutation: the legacy clone also persisted a catch-all insteadOf" \
	"$({ git -C "$TMPROOT/legacy" config --local --name-only --get-regexp '^url\.' 2>/dev/null || true; } | grep -c . || true)" "3"

# ===========================================================================
# 3. Breadth: the credential does not attach to a third party.
# ===========================================================================
run_clone third --repo third-party/dep --dest "$TMPROOT/third" \
	--rev "$THIRD_SHA" --shallow
check "a repo outside the scope still clones (it is public)" "$CASE_RC" "0"
V="$(journal_verdicts "/third-party/dep.git")"
case "$V" in
*public-auth*) bad "no credential is sent to an owner outside the scope" "journal said: $V" ;;
"") bad "no credential is sent to an owner outside the scope" "the third party was never contacted" ;;
*) ok "no credential is sent to an owner outside the scope" ;;
esac

# An owner whose name merely starts with ours. GitHub owner names are
# first-come, so this is registerable by anyone. Git's own path match breaks on
# `/` and refuses it; this pins that behaviour, which the scope format depends
# on.
mkdir -p "$SRV/metacraft-labs-evil"
EVIL_SHA="$(mk_repo metacraft-labs-evil/x.git)"
run_clone evil --repo metacraft-labs-evil/x --dest "$TMPROOT/evil" \
	--rev "$EVIL_SHA" --shallow
V="$(journal_verdicts "/metacraft-labs-evil/x.git")"
case "$V" in
*public-auth*) bad "an owner prefixed by ours receives no credential" "journal said: $V" ;;
"") bad "an owner prefixed by ours receives no credential" "it was never contacted" ;;
*) ok "an owner prefixed by ours receives no credential" ;;
esac

# ===========================================================================
# 4. .gitmodules: normalised for Nix, and never carrying a credential.
# ===========================================================================
run_clone gm --repo metacraft-labs/host --dest "$TMPROOT/gm" \
	--rev "$HOST_SHA" --submodules --commit-https-gitmodules
check "the --commit-https-gitmodules path succeeds" "$CASE_RC" "0"
check "the worktree .gitmodules no longer has an scp-style URL" \
	"$(grep -c 'git@github\.com:' "$TMPROOT/gm/.gitmodules" || true)" "0"
check "the worktree .gitmodules was rewritten to the https base" \
	"$(grep -cF "${BASE}metacraft-labs/tree-sitter-nim.git" "$TMPROOT/gm/.gitmodules" || true)" "1"
# ...and the rewritten spelling is one that actually resolves. The point of the
# rewrite is that a fetcher which cannot apply `insteadOf` (Nix, via libgit2's
# git_submodule_resolve_url) can still reach the submodule; a file that is
# merely differently spelled would satisfy a grep and fail a fetch.
check "the rewritten submodule URL is fetchable" \
	"$([[ -f $TMPROOT/gm/libs/tree-sitter-nim/README ]] && echo yes)" "yes"
check "the COMMITTED .gitmodules carries no credential" \
	"$(git -C "$TMPROOT/gm" show HEAD:.gitmodules | grep -c 'x-access-token' || true)" "0"
check "the commit was actually made" \
	"$(git -C "$TMPROOT/gm" log -1 --format=%s)" "CI: rewrite submodule URLs to HTTPS"
FOUND="$(credential_files "$TMPROOT/gm" | grep -c . || true)"
check "no credential under the clone that committed .gitmodules" "$FOUND" "0"

# MUTATION of the refusal path. A `.gitmodules` that already carries a
# credential must abort the commit rather than write a secret into a git object,
# which is the one place a later push or a packed artifact carries it off the
# machine. Reachable, so tested.
POISON_SHA="$(mk_repo metacraft-labs/poison.git \
	"[submodule \"s\"]
	path = s
	url = https://x-access-token:${TOKEN}@github.com/metacraft-labs/deep.git
" s "$DEEP_SHA")"
run_clone poison --repo metacraft-labs/poison --dest "$TMPROOT/poison" \
	--rev "$POISON_SHA" --commit-https-gitmodules
check "a credential-bearing .gitmodules is refused, not committed" "$CASE_RC" "1"
check "...and the refusal names no credential" \
	"$(grep -cF "$TOKEN" "$CASE_OUT" || true)" "0"
check "...and nothing was committed" \
	"$(git -C "$TMPROOT/poison" log -1 --format=%s 2>/dev/null)" "init"

# ===========================================================================
# 5. Nothing the scripts print carries the credential.
# ===========================================================================
LEAKED=0
for f in "$TMPROOT"/*.out; do
	[[ -f $f ]] || continue
	grep -qF "$TOKEN" "$f" && LEAKED=1
done
assert "no output of any run in this suite contains the token" "$LEAKED"

# The failure path is where a diagnostic gets written without thinking. Force
# one: a private repo with the credential scoped to the wrong owner.
CASE_OWNERS="some-other-org" run_clone denied --repo metacraft-labs/host \
	--dest "$TMPROOT/denied" --rev "$HOST_SHA" --shallow
check "an out-of-scope private clone FAILS rather than hanging on a prompt" \
	"$([[ $CASE_RC -ne 0 ]] && echo failed)" "failed"
if grep -q "metacraft-labs is not one of them" "$TMPROOT/denied.out"; then
	ok "...naming the owner that was not covered"
else
	bad "...naming the owner that was not covered" "diagnostic: $(head -c 400 "$TMPROOT/denied.out")"
fi
if grep -q "token-owner" "$TMPROOT/denied.out"; then
	ok "...and naming the input that fixes it"
else
	bad "...and naming the input that fixes it" "the diagnostic did not mention token-owner"
fi
check "...without printing the token" "$(grep -cF "$TOKEN" "$TMPROOT/denied.out" || true)" "0"

# ===========================================================================
# 6. The scoping library's own contracts.
# ===========================================================================
lib_case() { # runs a snippet with the library sourced, prints its output
	env -i PATH="$PATH" HOME="$TMPROOT" GH_TOKEN="$TOKEN" bash -c "
		set -euo pipefail
		. '$LIB'
		$1
	" 2>&1
}

# Appending, not clobbering. A caller may run after `setup-nix` has already put
# its own numbered configuration into the job environment; renumbering from zero
# would silently drop it for every later step.
OUT="$(env -i PATH="$PATH" HOME="$TMPROOT" GH_TOKEN="$TOKEN" \
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="user.name" GIT_CONFIG_VALUE_0="pre-existing" \
	bash -c "
		set -euo pipefail
		. '$LIB'
		scoped_git_auth_build
		scoped_git_auth_export
		printf '%s|%s|%s\n' \"\$GIT_CONFIG_COUNT\" \"\$GIT_CONFIG_KEY_0\" \"\$GIT_CONFIG_KEY_1\"
	" 2>&1)"
check "export appends to a pre-existing GIT_CONFIG_COUNT" \
	"$OUT" "2|user.name|http.https://github.com/metacraft-labs/.extraHeader"

# An identical pair added twice makes git send the same Authorization header
# twice, which is a malformed request and not a doubly-authenticated one.
OUT="$(lib_case "
	scoped_git_auth_build
	scoped_git_auth_export
	scoped_git_auth_export
	printf '%s\n' \"\$GIT_CONFIG_COUNT\"
")"
check "exporting twice does not duplicate the header" "$OUT" "1"

# The base is a test knob, and an unconstrained one would be a way to redirect
# every clone in the org — with the credential scoped to follow it — by setting
# one environment variable.
OUT="$(env -i PATH="$PATH" HOME="$TMPROOT" GH_TOKEN="$TOKEN" \
	GIT_AUTH_URL_BASE="https://evil.example/" bash -c "
		. '$LIB'
		scoped_git_auth_build
	" 2>&1)"
RC=$?
check "a non-github, non-loopback URL base is refused" "$RC" "2"

check "no token means no credential, and that is not an error" \
	"$(env -i PATH="$PATH" HOME="$TMPROOT" bash -c "
		set -euo pipefail
		. '$LIB'
		SCOPED_GIT_AUTH_REWRITES=1 scoped_git_auth_build
		scoped_git_auth_export
		printf '%s\n' \"\$GIT_CONFIG_COUNT\"
	" 2>&1)" "2"

# The owner cross-check: the whole point of it is the message, so assert the
# message.
OUT="$(env -i PATH="$PATH" HOME="$TMPROOT" TOKEN_OWNERS="metacraft-labs" bash -c "
	. '$LIB'
	scoped_git_auth_require_covered 'clone-siblings' metacraft-labs blocksense-network
" 2>&1)"
RC=$?
check "an owner outside the token scope is refused" "$RC" "1"
case "$OUT" in
*blocksense-network*) ok "...naming the owner that is not covered" ;;
*) bad "...naming the owner that is not covered" "message: $OUT" ;;
esac
case "$OUT" in
*token-owner*) ok "...and naming the input that fixes it" ;;
*) bad "...and naming the input that fixes it" "message: $OUT" ;;
esac
OUT="$(env -i PATH="$PATH" HOME="$TMPROOT" TOKEN_OWNERS="metacraft-labs blocksense-network" bash -c "
	. '$LIB'
	scoped_git_auth_require_covered 'clone-siblings' metacraft-labs blocksense-network
" 2>&1)"
check "owners that agree are accepted silently" "$?|$OUT" "0|"

# ===========================================================================
# 7. Static contracts over the two action.yml files.
#
# These are what fail against `main` on inspection alone, and they are cheap
# enough to be worth pinning: the defect is a single grep-visible shape, and a
# future edit that reintroduces it should not need a server to be caught.
# ===========================================================================
for a in "$ROOT/clone-siblings/action.yml" "$ROOT/clone-repo/action.yml"; do
	n="$(basename "$(dirname "$a")")"
	check "$n/action.yml embeds no credential in a URL" \
		"$(grep -c 'x-access-token' "$a" || true)" "0"
	check "$n/action.yml has no catch-all insteadOf for https://github.com/" \
		"$(grep -c 'insteadOf "https://github.com/"' "$a" || true)" "0"
	# Interpolating a secret into a `run:` body bakes it into the command file
	# the runner writes to disk and executes. Every mention of the token input
	# must be a bare `KEY: ${{ ... }}` assignment on a line of its own.
	MENTIONS="$(grep -c 'inputs\.gh-token' "$a" || true)"
	ASSIGNMENTS="$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*\$\{\{[[:space:]]*inputs\.gh-token[[:space:]]*\}\}[[:space:]]*$' "$a" || true)"
	check "$n/action.yml never interpolates the token into a command" \
		"$((MENTIONS - ASSIGNMENTS))" "0"
	check "$n/action.yml hard-codes no GitHub owner in a clone URL" \
		"$(grep -c 'github\.com/metacraft-labs/' "$a" || true)" "0"
done

# The coupling from TASK 3, as wiring rather than as documentation: one input
# value reaches both the sibling remote and the token scope.
#
# Stated as an INVARIANT over every occurrence rather than as an expected
# count. It used to be "sibling-owner appears once, token-owner twice", which
# is a fact about how many steps the action happened to have: `setup-dev-env`
# now invokes `clone-siblings` a second time (the follow-on clone for whatever
# a repo's committed `repro.lock` could not supply), and a literal count failed
# on the addition of a step that was wired perfectly correctly. Worse, the
# count would have PASSED had that new step hard-coded an owner while an
# existing one was deleted. What the contract is actually about is that no
# occurrence anywhere in the file is fed from anything other than the single
# `token-owner` input — which is what these two check, at any number of steps.
DEV_ENV="$ROOT/setup-dev-env/action.yml"
count_owner_lines() { # <key> [--from-input]
	local key="$1"
	if [[ ${2:-} == "--from-input" ]]; then
		grep -cE "^[[:space:]]*${key}:[[:space:]]*\\\$\{\{[[:space:]]*inputs\.token-owner[[:space:]]*\}\}[[:space:]]*\$" "$DEV_ENV" || true
	else
		grep -cE "^[[:space:]]*${key}:" "$DEV_ENV" || true
	fi
}
# `token-owner:` also appears as the action's own input declaration, which is
# a `token-owner:` line that is not an assignment; the totals below therefore
# count only lines that assign a `${{ }}` expression.
count_owner_assignments() { # <key>
	grep -cE "^[[:space:]]*${1}:[[:space:]]*\\\$\{\{" "$DEV_ENV" || true
}

SIB_TOTAL="$(count_owner_assignments sibling-owner)"
SIB_FROM="$(count_owner_lines sibling-owner --from-input)"
check "setup-dev-env feeds every sibling-owner from token-owner" \
	"${SIB_FROM}/${SIB_TOTAL}" "${SIB_TOTAL}/${SIB_TOTAL}"
check "  and there is at least one to feed" "$((SIB_TOTAL > 0))" "1"

TOK_TOTAL="$(count_owner_assignments token-owner)"
TOK_FROM="$(count_owner_lines token-owner --from-input)"
check "setup-dev-env feeds every token-owner from the same input" \
	"${TOK_FROM}/${TOK_TOTAL}" "${TOK_TOTAL}/${TOK_TOTAL}"
# One for `setup-nix` (the job-wide Git credential scope) and one per
# `clone-siblings` invocation; fewer than two means the coupling is gone.
check "  and it reaches setup-nix as well as clone-siblings" "$((TOK_TOTAL >= 2))" "1"

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
	echo "authenticated-clone: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "authenticated-clone: all contracts hold."
