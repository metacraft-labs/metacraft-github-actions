#!/usr/bin/env bash
#
# configure-git-auth-test.sh — contract suite for configure-git-auth.sh and for
# the parts of setup-nix/action.yml that hand it the token.
#
# `setup-nix` runs in almost every job in the org, so a regression in how it
# authenticates git does not fail this repo — it fails everyone else's. The
# contracts below are therefore about the two things that can go wrong in
# opposite directions:
#
#   TOO NARROW  — a metacraft-labs private fetch stops being authenticated, and
#                 every consumer's build breaks.
#   TOO BROAD   — the credential is attached to fetches it has no business on,
#                 or survives the job, which is the defect this replaced.
#
# NO MOCKS. Every assertion runs the real `configure-git-auth.sh` against a real
# `git` binary in a sandbox HOME, and asks git itself which credential it would
# present — via `git config --get-urlmatch` (the matcher git uses when building
# a request) and `git ls-remote --get-url` (the rewriter it applies before
# making one). Nothing here re-implements git's URL matching, because a
# re-implementation would agree with itself while disagreeing with git.
#
# Asking BOTH channels is load-bearing, not thoroughness theatre: the defect
# being fixed carried its credential in the URL, which the header matcher cannot
# see. Against the old code a header-only suite reports every third-party fetch
# as unauthenticated — the right answer for the wrong reason — and passes
# unchanged. It was written that way first and did exactly that.
#
# Run: bash setup-nix/configure-git-auth-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/configure-git-auth.sh"
ACTION_YML="$HERE/action.yml"
[[ -f $SCRIPT ]] || {
	echo "configure-git-auth-test: cannot find $SCRIPT" >&2
	exit 2
}

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

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A token shaped like a real GitHub App installation token, so a substring
# search for it cannot accidentally match ordinary text.
TOKEN="ghs_TESTONLYnotarealtoken0000000000000000"

# `run_auth <case-name> [env assignments...]` — run configure-git-auth.sh in a
# fresh sandbox HOME. Sets, for the caller:
#   CASE_HOME    the sandbox HOME
#   CASE_ENV     the captured GITHUB_ENV file
#   CASE_OUT     merged stdout+stderr
#   CASE_RC      exit status
run_auth() {
	local name="$1"
	shift
	CASE_HOME="$TMPROOT/$name/home"
	CASE_ENV="$TMPROOT/$name/github_env"
	CASE_OUT="$TMPROOT/$name/out"
	mkdir -p "$CASE_HOME"
	: >"$CASE_ENV"
	CASE_RC=0
	env -i \
		PATH="$PATH" \
		HOME="$CASE_HOME" \
		GITHUB_ENV="$CASE_ENV" \
		GH_TOKEN="$TOKEN" \
		"$@" \
		bash "$SCRIPT" >"$CASE_OUT" 2>&1 || CASE_RC=$?
}

# `urlmatch <url>` — ask git, using the emitted process-scoped configuration and
# nothing else, which Authorization header it would send for <url>. The captured
# GITHUB_ENV lines are handed straight to `env` as KEY=VALUE, which is exactly
# what the Actions runner does with them for the following steps.
urlmatch() {
	local url="$1" line
	local -a envv=()
	while IFS= read -r line || [[ -n $line ]]; do
		[[ -z $line ]] && continue
		envv+=("$line")
	done <"$CASE_ENV"
	env -i PATH="$PATH" HOME="$CASE_HOME" "${envv[@]}" \
		git config --get-urlmatch http.extraHeader "$url" 2>/dev/null
}

# `sent_url <url>` — the URL git would actually contact for <url>, after every
# `url.*.insteadOf` rewrite in effect. Offline; `--get-url` only resolves.
#
# This exists because `http.extraHeader` matching CANNOT see a credential
# smuggled into the URL by a rewrite, which is precisely the shape of the defect
# being fixed. A suite that only asked `--get-urlmatch` would report every
# third-party URL as unauthenticated while the old catch-all was busily
# injecting a token into all of them, and would therefore pass unchanged against
# the code it is supposed to condemn.
sent_url() {
	local url="$1" line
	local -a envv=()
	while IFS= read -r line || [[ -n $line ]]; do
		[[ -z $line ]] && continue
		envv+=("$line")
	done <"$CASE_ENV"
	env -i PATH="$PATH" HOME="$CASE_HOME" "${envv[@]}" \
		git ls-remote --get-url "$url" 2>/dev/null
}

# `credential_for <url>` — everything git would present as authentication when
# fetching <url>, by BOTH available channels. Empty output means the fetch is
# genuinely unauthenticated; that is what the negative contracts assert.
credential_for() {
	local url="$1" hdr rewritten
	hdr="$(urlmatch "$url")"
	rewritten="$(sent_url "$url")"
	[[ $rewritten != "$url" ]] && printf 'url rewritten to: %s\n' "$rewritten"
	[[ -n $hdr ]] && printf '%s\n' "$hdr"
	return 0
}

EXPECT_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\r\n')"

# ---------------------------------------------------------------------------
# Default scope: the org's own repositories, and only those.
# ---------------------------------------------------------------------------
run_auth default
check "runs clean with only GH_TOKEN set" "$CASE_RC" "0"

check "own-org repo is authenticated" \
	"$(credential_for https://github.com/metacraft-labs/codetracer.git)" "$EXPECT_HEADER"
check "own-org repo without .git suffix is authenticated" \
	"$(credential_for https://github.com/metacraft-labs/reprobuild)" "$EXPECT_HEADER"
check "own-org repo at a deeper path is authenticated" \
	"$(credential_for https://github.com/metacraft-labs/codetracer.git/info/refs)" "$EXPECT_HEADER"
# ...by a header, with the URL left alone. A credential in the URL reaches
# git-remote-https's argv (readable in /proc on a shared runner), the clone's
# .git/config, and git's own failure messages.
check "the own-org URL itself carries no credential" \
	"$(sent_url https://github.com/metacraft-labs/codetracer.git)" \
	"https://github.com/metacraft-labs/codetracer.git"

# The whole point. Each of these is a real fetch some job in the org performs.
check "nixpkgs is NOT authenticated" \
	"$(credential_for https://github.com/NixOS/nixpkgs)" ""
check "status-im is NOT authenticated" \
	"$(credential_for https://github.com/status-im/nim-stew)" ""
check "nim-lang is NOT authenticated" \
	"$(credential_for https://github.com/nim-lang/Nim)" ""
# An owner that merely starts with ours must not slip through the prefix match;
# GitHub owner names are first-come, so this is registerable by anyone. Git
# breaks its path match on `/` and so refuses this by itself — the contract is
# here to pin that git behaviour, which the scope format depends on, not to
# check a guard of our own.
check "an owner prefixed by ours is NOT authenticated" \
	"$(credential_for https://github.com/metacraft-labs-evil/x)" ""
check "bare github.com is NOT authenticated" \
	"$(credential_for https://github.com/)" ""
check "another host is NOT authenticated" \
	"$(credential_for https://gitlab.com/metacraft-labs/x)" ""
check "plain http to our own org is NOT authenticated" \
	"$(credential_for http://github.com/metacraft-labs/codetracer.git)" ""

# ---------------------------------------------------------------------------
# Nothing carrying the credential survives the job.
# ---------------------------------------------------------------------------
if grep -rqF "$TOKEN" "$CASE_HOME" 2>/dev/null; then
	bad "the raw token is not written anywhere under HOME" \
		"found in: $(grep -rlF "$TOKEN" "$CASE_HOME" 2>/dev/null | tr '\n' ' ')"
else
	ok "the raw token is not written anywhere under HOME"
fi
B64="${EXPECT_HEADER#AUTHORIZATION: basic }"
if grep -rqF "$B64" "$CASE_HOME" 2>/dev/null; then
	bad "the encoded credential is not written anywhere under HOME" \
		"found in: $(grep -rlF "$B64" "$CASE_HOME" 2>/dev/null | tr '\n' ' ')"
else
	ok "the encoded credential is not written anywhere under HOME"
fi

# A persisted rewrite would put the credential back into every URL, which is
# both of the above failures at once and the specific shape of the old defect.
if HOME="$CASE_HOME" git config --global --get-regexp '^url\.' 2>/dev/null |
	grep -q 'x-access-token'; then
	bad "no credential-bearing url.*.insteadOf is left in ~/.gitconfig"
else
	ok "no credential-bearing url.*.insteadOf is left in ~/.gitconfig"
fi

# ...but the credential-FREE scheme rewrites must still be there: `.gitmodules`
# in this org spells submodule URLs in all three styles and git reads them
# before any per-job configuration applies.
check "ssh scp-style submodule URLs are still rewritten" \
	"$(HOME="$CASE_HOME" git config --global --get-all url."https://github.com/".insteadOf |
		grep -cx 'git@github\.com:')" "1"
check "ssh:// submodule URLs are still rewritten" \
	"$(HOME="$CASE_HOME" git config --global --get-all url."https://github.com/".insteadOf |
		grep -cx 'ssh://git@github\.com/')" "1"

# ---------------------------------------------------------------------------
# Nothing is printed that a log should not carry.
# ---------------------------------------------------------------------------
if grep -qF "$TOKEN" "$CASE_OUT"; then
	bad "the raw token is never printed"
else
	ok "the raw token is never printed"
fi
# The derived blob is printed exactly once, and only as the payload of
# ::add-mask::, which the runner consumes and replaces with '***'. Any OTHER
# occurrence would be a real log leak.
check "the encoded credential appears only inside ::add-mask::" \
	"$(grep -cF "$B64" "$CASE_OUT")" "1"
check "that one occurrence is an ::add-mask:: command" \
	"$(grep -cF "::add-mask::$B64" "$CASE_OUT")" "1"

# ---------------------------------------------------------------------------
# Job-scoped, not global: the emitted configuration is process-scoped git env.
# ---------------------------------------------------------------------------
check "GIT_CONFIG_COUNT covers every emitted pair" \
	"$(grep -c '^GIT_CONFIG_KEY_' "$CASE_ENV")" \
	"$(sed -n 's/^GIT_CONFIG_COUNT=//p' "$CASE_ENV")"
check "the credential is emitted as an extraHeader, not a URL" \
	"$(grep -c '^GIT_CONFIG_KEY_0=http\.https://github\.com/metacraft-labs/\.extraHeader$' "$CASE_ENV")" "1"
# Emitting anything else through $GITHUB_ENV applies it to every step of every
# job in the org. Pin the emitted set so a future addition has to be argued for
# rather than slipped in — a `credential.helper` reset was proposed here and
# rejected on exactly that ground.
check "nothing but the scoped headers is forced on every step" \
	"$(grep -c '^GIT_CONFIG_KEY_' "$CASE_ENV")" "1"
check "git is told never to prompt" \
	"$(grep -c '^GIT_TERMINAL_PROMPT=0$' "$CASE_ENV")" "1"

# ---------------------------------------------------------------------------
# Migration: a runner whose $HOME predates this change carries a live token in
# ~/.gitconfig. It must be evicted, or it keeps catching everything.
# ---------------------------------------------------------------------------
STALE_HOME="$TMPROOT/stale/home"
mkdir -p "$STALE_HOME"
HOME="$STALE_HOME" git config --global \
	url."https://x-access-token:ghs_STALEtokenFromAPreviousJob000000000@github.com/".insteadOf \
	"https://github.com/"
check "precondition: the stale rewrite is installed" \
	"$(HOME="$STALE_HOME" git config --global --get-regexp '^url\.' | grep -c 'x-access-token')" "1"
CASE_RC=0
env -i PATH="$PATH" HOME="$STALE_HOME" GITHUB_ENV="$TMPROOT/stale/env" GH_TOKEN="$TOKEN" \
	bash "$SCRIPT" >"$TMPROOT/stale/out" 2>&1 || CASE_RC=$?
check "the run over a stale HOME still succeeds" "$CASE_RC" "0"
check "a stale credential-bearing rewrite from an earlier job is evicted" \
	"$(HOME="$STALE_HOME" git config --global --get-regexp '^url\.' 2>/dev/null |
		grep -c 'x-access-token')" "0"
if grep -rqF "ghs_STALEtokenFromAPreviousJob000000000" "$STALE_HOME" 2>/dev/null; then
	bad "the stale token is gone from ~/.gitconfig"
else
	ok "the stale token is gone from ~/.gitconfig"
fi

# Re-running in the same HOME must not accumulate duplicate rewrite values.
env -i PATH="$PATH" HOME="$STALE_HOME" GITHUB_ENV="$TMPROOT/stale/env" GH_TOKEN="$TOKEN" \
	bash "$SCRIPT" >/dev/null 2>&1
check "re-running does not duplicate the scheme rewrites" \
	"$(HOME="$STALE_HOME" git config --global --get-all url."https://github.com/".insteadOf | wc -l | tr -d ' ')" "2"

# ---------------------------------------------------------------------------
# The deliberate escape hatch for cross-org private clones (a per-repo minted
# secret). It used to work by accident off the catch-all; it now has to be
# declared, and declaring it must widen the scope by EXACTLY what was declared.
# ---------------------------------------------------------------------------
run_auth extra EXTRA_TOKEN_URL_PREFIXES="https://github.com/some-partner/one-repo.git"
check "a declared cross-org repo is authenticated" \
	"$(credential_for https://github.com/some-partner/one-repo.git)" "$EXPECT_HEADER"
check "declaring one repo does not authenticate its owner's other repos" \
	"$(credential_for https://github.com/some-partner/another-repo.git)" ""
check "declaring a cross-org repo keeps the own-org scope" \
	"$(credential_for https://github.com/metacraft-labs/codetracer.git)" "$EXPECT_HEADER"
check "declaring a cross-org repo does not widen to third parties" \
	"$(credential_for https://github.com/NixOS/nixpkgs)" ""

run_auth owners TOKEN_OWNERS="metacraft-labs other-org"
check "a second declared owner is authenticated" \
	"$(credential_for https://github.com/other-org/x)" "$EXPECT_HEADER"
check "declaring a second owner keeps the first" \
	"$(credential_for https://github.com/metacraft-labs/codetracer.git)" "$EXPECT_HEADER"
check "declaring a second owner does not widen to third parties" \
	"$(credential_for https://github.com/NixOS/nixpkgs)" ""

# A non-https prefix cannot be honoured by `http.<url>.*` and must be refused
# rather than silently ignored — a silently ignored scope is an unauthenticated
# fetch that looks configured.
run_auth badprefix EXTRA_TOKEN_URL_PREFIXES="git@github.com:some-partner/x.git"
check "a non-https extra prefix is refused, not ignored" "$CASE_RC" "2"

# An empty scope would install a credential that matches nothing, i.e. silently
# unauthenticate the whole org.
run_auth noscope TOKEN_OWNERS=" "
check "an empty scope is refused, not silently installed" "$CASE_RC" "2"

# ---------------------------------------------------------------------------
# Static contracts over action.yml — the wiring the suite above cannot see.
# ---------------------------------------------------------------------------
if [[ -f $ACTION_YML ]]; then
	# The defect in one line. A credential-bearing rewrite anywhere in the action
	# re-globalises the token no matter what this script does.
	check "action.yml installs no credential-bearing url rewrite" \
		"$(grep -c 'x-access-token:\${{' "$ACTION_YML")" "0"
	check "action.yml has no catch-all insteadOf for https://github.com/" \
		"$(grep -c 'insteadOf "https://github.com/"' "$ACTION_YML")" "0"
	# Interpolating a secret into a `run:` body bakes it into the rendered
	# command the runner writes to a script file and executes; routing it
	# through `env:` (or a `with:` input of a nested action) does not. Every
	# mention of the token input must therefore be a bare `KEY: ${{ ... }}`
	# assignment on a line of its own.
	MENTIONS="$(grep -c 'inputs\.gh-token' "$ACTION_YML")"
	ASSIGNMENTS="$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*\$\{\{[[:space:]]*inputs\.gh-token[[:space:]]*\}\}[[:space:]]*$' "$ACTION_YML")"
	check "action.yml never interpolates the token into a command" \
		"$((MENTIONS - ASSIGNMENTS))" "0"
	check "action.yml delegates git auth to configure-git-auth.sh" \
		"$(grep -cE '^[[:space:]]*run:.*configure-git-auth\.sh' "$ACTION_YML")" "1"
else
	bad "action.yml is present next to this suite"
fi

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
	echo "configure-git-auth: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "configure-git-auth: all contracts hold."
