#!/usr/bin/env bash
#
# clone-siblings-step-test.sh — contract suite for the composite STEP in
# clone-siblings/action.yml, as opposed to the resolver it calls.
#
# WHY A SECOND SUITE
# ------------------
# `resolve-sibling-rev-test.sh` covers the lock reader, and covers it well: 86
# contracts over both lock layouts, the layering rules, and every exit code. It
# cannot cover the action, because the action is a `run:` block inside YAML —
# and every defect this suite was written for lives in that block, downstream of
# a resolver that behaved correctly:
#
#   * an explicit `name=ref` override was handed to `git fetch` UNVALIDATED. The
#     resolver's `check_rev_shape` exists because a revision reaching `git fetch`
#     unchecked is how `revision = "main"` becomes a silent branch-tip build and
#     how `--upload-pack=<cmd>` becomes command execution on the runner. The
#     override path bypassed it completely: it never went near the resolver.
#   * a sibling the lock does not NAME (resolver exit 4) was reported as
#     `Workspace lock ... exists but cannot be used`, which is false — the lock
#     is intact; the repo is simply not a member of the workspace project the
#     lock describes — and which points the reader at the wrong artifact.
#   * the first such sibling aborted the whole step, so a caller migrating nine
#     repos onto the lock learned about them one CI run at a time, after having
#     already cloned some of the others.
#
# HOW THE STEP IS RUN
# -------------------
# The `run:` body is EXTRACTED FROM action.yml at test time and executed. It is
# not copied here and it is not re-implemented: a copy would be the thing that
# drifts, and this suite exists because drift between "what is tested" and "what
# ships" is the failure mode. The `${{ }}` expressions are substituted from a
# table, and an expression the table does not know about is a hard error — so
# adding one to action.yml fails this suite instead of silently testing a
# different program.
#
# NO MOCKS, one shim. The real `resolve-sibling-rev.sh`, the real
# `authenticated-clone.sh`, the real `scoped-git-auth.sh`, real git, real
# repositories, real lock files. The single substitution is a `git` wrapper on
# PATH that rewrites `https://github.com/<owner>/<name>` to a local bare
# repository, because the alternative is network access to GitHub from a
# contract suite. It rewrites URLs and nothing else, so every argument the
# action passes to git — including a hostile `--upload-pack=` — reaches the real
# git exactly as the action wrote it. That is the point: the RCE contract below
# would be untestable against a git that was faked.
#
# MUTATION-VERIFIED. Each contract here was first observed to FAIL against the
# unfixed action (see the header of each section for the message it produced).
#
# Run: bash clone-siblings/clone-siblings-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ACTION="$HERE/action.yml"

[[ -f $ACTION ]] || {
	echo "clone-siblings-step-test: cannot find $ACTION" >&2
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
contains() { # <desc> <haystack> <needle>
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "did not contain [$3]" ;;
	esac
}
lacks() { # <desc> <haystack> <needle>
	case "$2" in
	*"$3"*) bad "$1" "unexpectedly contained [$3]" ;;
	*) ok "$1" ;;
	esac
}

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. The step body is a script FILE now; run the shipped one.
# ---------------------------------------------------------------------------
#
# This suite used to scrape the `run: |` block out of action.yml with a bash
# YAML reader and substitute its `${{ }}` expressions from a table. That was the
# best available option while the body lived inside YAML, and it is no longer
# needed: the body moved into `clone-siblings.sh` because a composite `run:`
# body is a TEMPLATE STRING that GitHub refuses past a length limit, and the
# block had 76 characters of headroom left (see
# .github/assert-composite-run-size.sh for the outage that established the
# budget, and clone-siblings.sh's own header). So the file that ships is now the
# file this suite executes, with no extraction step in between to drift.
#
# What extraction used to buy — "action.yml cannot change out from under this
# suite without failing it" — is bought instead by the two checks below: the
# action must still INVOKE this script, and it must still declare every
# environment variable the script reads. A rename, or an `env:` entry dropped
# while refactoring, would otherwise leave a green suite exercising a script
# that nothing runs, or running it with an input the action no longer passes.
STEP="$HERE/clone-siblings.sh"
[[ -f $STEP ]] || {
	echo "clone-siblings-step-test: cannot find $STEP" >&2
	exit 2
}
bash -n "$STEP" || {
	echo "clone-siblings-step-test: $STEP is not valid bash (see above)." >&2
	exit 2
}

ACTION_TEXT="$(<"$ACTION")"
case "$ACTION_TEXT" in
*'run: bash "${GITHUB_ACTION_PATH}/clone-siblings.sh"'*) ;;
*)
	echo "clone-siblings-step-test: $ACTION no longer runs clone-siblings.sh." >&2
	echo "  This suite executes that file directly, so it would keep passing while the" >&2
	echo "  action ran something else entirely. Expected the step to be exactly:" >&2
	echo '      run: bash "${GITHUB_ACTION_PATH}/clone-siblings.sh"' >&2
	exit 2
	;;
esac
# Line-wise, and only a line that IS the key: the prose above and in action.yml
# both mention `run: |` in passing, and a substring match on the whole file
# would fire on the comment explaining why the key must not come back.
while IFS= read -r _l || [[ -n $_l ]]; do
	_s="${_l#"${_l%%[![:space:]]*}"}"
	if [[ $_s == "run: |" || $_s == "run: |-" ]]; then
		echo "clone-siblings-step-test: $ACTION has grown an inline block 'run:' body again." >&2
		echo "  A composite run: body is a template string GitHub rejects past a length" >&2
		echo "  limit, failing every consumer's job before its first step. Put the code in" >&2
		echo "  a script file beside the action; see .github/assert-composite-run-size.sh." >&2
		exit 2
	fi
done <"$ACTION"

# Every environment variable clone-siblings.sh reads that is not a runner
# builtin must be declared in the step's `env:`.
for _v in GH_TOKEN SIBLINGS_INPUT SIBLING_OWNER JOB_TOKEN_OWNERS \
	MANIFESTS_REPO INPUT_MANIFESTS_REF PRIVATE_MANIFESTS_REPO \
	INPUT_PRIVATE_MANIFESTS_REF ON_LOCK_OVERRIDE GIT_AUTH_DIR \
	PR_BASE_SHA EVENT_BEFORE; do
	case "$ACTION_TEXT" in
	*"        ${_v}: "*) ;;
	*)
		echo "clone-siblings-step-test: $ACTION does not pass '${_v}' in the step's env:." >&2
		echo "  clone-siblings.sh reads it, so the action would run with it unset while" >&2
		echo "  this suite supplies it and passes." >&2
		exit 2
		;;
	esac
done

# ---------------------------------------------------------------------------
# 2. Fixtures: local bare repositories + a `git` shim that maps GitHub URLs.
# ---------------------------------------------------------------------------
SRV="$TMPROOT/srv"
mkdir -p "$SRV/metacraft-labs" "$TMPROOT/bin"

REAL_GIT="$(command -v git)"
cat >"$TMPROOT/bin/git" <<SHIM
#!/usr/bin/env bash
# URL-only rewrite: https://github.com/<x> -> file://$SRV/<x>. Every other
# argument, including anything that looks like an option, is passed through
# untouched so the real git parses it exactly as the action wrote it.
args=()
for a in "\$@"; do
  case "\$a" in
    https://github.com/*) args+=("file://$SRV/\${a#https://github.com/}") ;;
    *) args+=("\$a") ;;
  esac
done
exec "$REAL_GIT" "\${args[@]}"
SHIM
chmod +x "$TMPROOT/bin/git"

git_q() { "$REAL_GIT" "$@" >/dev/null 2>&1; }

# `mk_repo <name> [<branch>]` — a bare repo under metacraft-labs, one commit on
# `dev`. Prints the commit SHA.
mk_repo() {
	local name="$1" branch="${2:-dev}"
	local work="$TMPROOT/build/$name"
	git_q init --bare -b "$branch" "$SRV/metacraft-labs/$name.git"
	# Sibling clones fetch an exact SHA, which a server only serves when asked.
	git_q -C "$SRV/metacraft-labs/$name.git" config uploadpack.allowAnySHA1InWant true
	git_q -C "$SRV/metacraft-labs/$name.git" config uploadpack.allowReachableSHA1InWant true
	mkdir -p "$work"
	git_q -C "$work" init -b "$branch" .
	printf 'content of %s\n' "$name" >"$work/README"
	git_q -C "$work" add README
	git_q -C "$work" -c user.name=CI -c user.email=ci@local commit --no-gpg-sign -m "init $name"
	git_q -C "$work" push "$SRV/metacraft-labs/$name.git" "$branch"
	"$REAL_GIT" -C "$work" rev-parse HEAD
}

# The nine repos `codetracer`'s `setup-isonim-siblings` clones, in its order.
# Four of them are members of the `codetracer` workspace project and are pinned
# by its lock; five belong to the `isonim` project and are not. That split is
# not invented for this suite — it is what
# metacraft-labs/metacraft-manifests@latest carries today, and it is the reason
# that action still hard-codes `ref: dev` for all nine.
IN_LOCK=(nim-everywhere nim-acp nim-agent-harbor nim-agents)
NOT_IN_LOCK=(isonim isonim-tui isonim-gpui nim-termctl nim-pty)

declare -a REPO_NAMES=() REPO_SHAS=()
for n in "${IN_LOCK[@]}" "${NOT_IN_LOCK[@]}"; do
	REPO_NAMES+=("$n")
	REPO_SHAS+=("$(mk_repo "$n")")
done
sha_of() { # <name>
	local i
	for i in "${!REPO_NAMES[@]}"; do
		[[ ${REPO_NAMES[i]} == "$1" ]] && {
			printf '%s' "${REPO_SHAS[i]}"
			return 0
		}
	done
	return 1
}

# The commit under test, and a manifests repo whose lock pins the four members.
SELF_SHA="1111111111111111111111111111111111111111"
MAN_WORK="$TMPROOT/build/manifests"
mk_manifests() { # <lock-body-file-or-empty>
	rm -rf "$SRV/metacraft-labs/metacraft-manifests.git" "$MAN_WORK"
	git_q init --bare -b latest "$SRV/metacraft-labs/metacraft-manifests.git"
	mkdir -p "$MAN_WORK"
	git_q -C "$MAN_WORK" init -b latest .
	if [[ -n ${1:-} ]]; then
		mkdir -p "$MAN_WORK/locks/codetracer/codetracer"
		cp "$1" "$MAN_WORK/locks/codetracer/codetracer/$SELF_SHA.toml"
	else
		mkdir -p "$MAN_WORK/locks/codetracer"
		printf 'placeholder\n' >"$MAN_WORK/locks/codetracer/.keep"
	fi
	git_q -C "$MAN_WORK" add -A
	git_q -C "$MAN_WORK" -c user.name=CI -c user.email=ci@local commit --no-gpg-sign -m locks
	git_q -C "$MAN_WORK" push "$SRV/metacraft-labs/metacraft-manifests.git" latest
}

LOCK_OK="$TMPROOT/lock-ok.toml"
{
	printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nrepo = "codetracer"\n\n'
	for n in "${IN_LOCK[@]}"; do
		printf '[[repo]]\nname = "%s"\npath = "%s"\nrevision = "%s"\n\n' "$n" "$n" "$(sha_of "$n")"
	done
} >"$LOCK_OK"

LOCK_BROKEN="$TMPROOT/lock-broken.toml"
printf 'schema = "reprobuild.workspace.lock.v1"\n\n[[repo]]\nname = "nim-acp"\nrevision = "main"\n' >"$LOCK_BROKEN"

# A lock that answers the PROBE sibling correctly and is malformed only for a
# LATER one. Without it the per-sibling exit-5 path is unreachable in this
# suite — the probe already stops such a lock — and an unreached error path is
# an error path nobody has checked.
LOCK_LATE_BAD="$TMPROOT/lock-late-bad.toml"
{
	printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nrepo = "codetracer"\n\n'
	printf '[[repo]]\nname = "nim-acp"\nrevision = "%s"\n\n' "$(sha_of nim-acp)"
	printf '[[repo]]\nname = "nim-agents"\nrevision = "main"\n'
} >"$LOCK_LATE_BAD"

# ---------------------------------------------------------------------------
# 3. The driver.
# ---------------------------------------------------------------------------
WS_PARENT="$TMPROOT/ws"
SUMMARY="$TMPROOT/step-summary.md"
OUT=""
RC=0
run_step() { # <siblings-input> [<on-lock-override>]
	rm -rf "$WS_PARENT"
	mkdir -p "$WS_PARENT/codetracer" "$TMPROOT/runner-temp"
	rm -rf "$TMPROOT/runner-temp"
	mkdir -p "$TMPROOT/runner-temp"
	: >"$TMPROOT/github-env"
	: >"$SUMMARY"
	OUT="$(
		PATH="$TMPROOT/bin:$PATH" \
			GH_TOKEN="" \
			SIBLINGS_INPUT="$1" \
			SIBLING_OWNER="metacraft-labs" \
			JOB_TOKEN_OWNERS="metacraft-labs" \
			MANIFESTS_REPO="metacraft-labs/metacraft-manifests" \
			INPUT_MANIFESTS_REF="latest" \
			PRIVATE_MANIFESTS_REPO="" \
			INPUT_PRIVATE_MANIFESTS_REF="" \
			ON_LOCK_OVERRIDE="${2:-warn}" \
			GIT_AUTH_DIR="$ROOT/git-auth" \
			GITHUB_ACTION_PATH="$HERE" \
			GITHUB_WORKSPACE="$WS_PARENT/codetracer" \
			GITHUB_REPOSITORY="metacraft-labs/codetracer" \
			GITHUB_SHA="$SELF_SHA" \
			GITHUB_EVENT_NAME="push" \
			EVENT_BEFORE="" \
			PR_BASE_SHA="" \
			RUNNER_TEMP="$TMPROOT/runner-temp" \
			GITHUB_ENV="$TMPROOT/github-env" \
			GITHUB_STEP_SUMMARY="$SUMMARY" \
			bash "$STEP" 2>&1
	)"
	RC=$?
	# `SHOW_STEP_OUTPUT=1 bash clone-siblings/clone-siblings-step-test.sh` prints
	# what the step actually said. Every contract below is a claim about this
	# text, and a claim about text is only as good as the ability to read it.
	if [[ -n ${SHOW_STEP_OUTPUT:-} ]]; then
		echo "--- step: siblings=[${1//$'\n'/ }] rc=$RC ---"
		echo "$OUT"
		echo "--- end ---"
	fi
}

NINE=""
for n in "${IN_LOCK[@]}" "${NOT_IN_LOCK[@]}"; do NINE="${NINE}${n}"$'\n'; done

# ===========================================================================
# 4. The happy path still works.
#
# Everything below changes only failure and validation paths, so the first
# contract is that the path every consumer is on is untouched.
# ===========================================================================
mk_manifests "$LOCK_OK"

FOUR=""
for n in "${IN_LOCK[@]}"; do FOUR="${FOUR}${n}"$'\n'; done
run_step "$FOUR"
check "four lock-pinned siblings clone cleanly" "$RC" "0"
for n in "${IN_LOCK[@]}"; do
	check "  $n is checked out at the locked revision" \
		"$("$REAL_GIT" -C "$WS_PARENT/$n" rev-parse HEAD 2>/dev/null)" "$(sha_of "$n")"
done
contains "CT_SIBLING_PATHS is exported for later steps" "$(<"$TMPROOT/github-env")" "CT_SIBLING_PATHS="

# ===========================================================================
# 5. Explicit `name=ref` overrides are revisions too.
#
# RED against the unfixed action:
#   - `nim-acp=dev` cloned the branch tip and printed only
#       nim-acp -> dev (override)
#     with no warning anywhere in the log.
#   - `nim-acp=--upload-pack=...` ran the payload: git parses options after the
#     remote, so `git fetch --depth 1 origin --upload-pack=<cmd>` executes <cmd>
#     on the runner. The marker file below was created and the step exited 0 on
#     `main`.
# ===========================================================================

# 5a. A branch-name override still works — five workflows in this org pass one
#     today (`codetracer-native-recorder=main`, `codetracer-trace-format=main`,
#     ...) and this action reaches them immediately at `@main`. It must not
#     start failing. It must, however, stop being silent.
run_step "nim-acp=dev"
check "a branch-name override is still accepted" "$RC" "0"
contains "...and is announced as an override" "$OUT" "(override)"
contains "...and warns that it is not lock-pinned" "$OUT" "::warning::"
contains "...naming the sibling it applies to" "$OUT" "nim-acp"

# 5b. A 40-hex override is a real pin, so it must NOT be warned about — a
#     warning on the correct spelling trains people to ignore warnings.
run_step "nim-acp=$(sha_of nim-acp)"
check "a 40-hex override is accepted" "$RC" "0"
lacks "...and is not warned about" "$OUT" "::warning::"

# `refused_by_shape <desc> <siblings-input>` — the assertion that has teeth.
#
# "The step exited 1" is NOT enough and was actively misleading while this suite
# was being written: a bad ref that reaches `git fetch` also exits 1, from git,
# after a clone and a network round trip. Mutating the guard away therefore left
# an exit-1 test passing for the wrong reason. So the contract is the specific
# one: refused BY THE SHAPE CHECK, which means the error text is the shape
# error, the clone loop was never entered (no `-> ... (override)` line), and
# nothing landed in the workspace parent.
refused_by_shape() { # <desc> <siblings-input>
	run_step "$2"
	check "$1" "$RC" "1"
	contains "  ...by the shape check, before any clone" "$OUT" "not a usable ref"
	lacks "  ...so no revision was ever handed to git" "$OUT" "(override)"
	check "  ...and nothing was cloned" \
		"$([[ -e "$WS_PARENT/nim-acp" ]] && echo yes || echo no)" "no"
}

# 5c. Option injection — the live one. `git fetch <remote> --upload-pack=<cmd>`
#     hands <cmd> to `sh -c`, so this is command execution on the runner, and
#     the fetch then SUCCEEDS, so the step goes green while it happens. The
#     payload carries no literal whitespace because the `siblings` input is
#     whitespace-separated; `$IFS` is expanded by the shell git spawns, not by
#     the action. Verified against git directly before being asserted here.
MARKER="$TMPROOT/pwned"
rm -f "$MARKER"
refused_by_shape "an override that git would parse as an option is refused" \
	"nim-acp=--upload-pack=touch\$IFS$MARKER;git-upload-pack"
check "  ...and the payload never ran" "$([[ -e $MARKER ]] && echo yes || echo no)" "no"
contains "  ...with an error that names the sibling" "$OUT" "nim-acp"

# 5d. The leading-dash rule ON ITS OWN. `-uecho` is composed entirely of
#     characters the whitelist allows, so this is the only contract that fails
#     if that rule is removed — which is exactly what makes it worth having
#     separately from 5c, where two independent rules both reject the payload.
refused_by_shape "a leading-dash override is refused" "nim-acp=-uecho"

# 5e. The character whitelist ON ITS OWN. `dev;touch` has no leading dash, so
#     only the whitelist rejects it. (A ref cannot contain whitespace here at
#     all: the `siblings` input is whitespace-separated, so a space ends the
#     entry rather than entering the ref. There is nothing to test there.)
refused_by_shape "an override containing a shell metacharacter is refused" \
	"nim-acp=dev;touch"
refused_by_shape "an override containing '=' is refused" "nim-acp=dev=x"
refused_by_shape "an override containing '..' is refused" "nim-acp=dev..main"

# 5f. Spellings that ARE legitimate refs keep working.
run_step "nim-acp=refs/heads/dev"
check "a fully-qualified ref override is accepted" "$RC" "0"

# 5g. A trailing `=` has always meant "fall back to the lock", and the
#     validation must not turn an empty override into a refusal.
run_step "nim-acp="
check "a trailing '=' still falls back to the lock" "$RC" "0"
contains "...resolving from the lock, not as an override" "$OUT" "(lock)"

# ===========================================================================
# 6. A sibling the lock does not NAME is a membership fact, not a broken lock.
#
# RED against the unfixed action, for the nine-repo `setup-isonim-siblings` set:
#
#   ::error::Workspace lock for codetracer@1111... exists but cannot be used
#   (resolve-sibling-rev exit 4); see its diagnostic above.
#
# Three things wrong with that, all of which these contracts pin:
#   1. the lock CAN be used — it pins the other four correctly;
#   2. it names none of the five siblings actually missing;
#   3. it stops at the first one, so the remaining four are never reported.
# ===========================================================================
run_step "$NINE"
check "nine siblings, five unpinned: the step fails" "$RC" "1"
lacks "...without blaming the lock" "$OUT" "cannot be used"
for n in "${NOT_IN_LOCK[@]}"; do
	contains "...naming the unpinned sibling $n" "$OUT" "$n"
done
contains "...pointing at the manifest repo that would fix it" "$OUT" "metacraft-labs/metacraft-manifests"
contains "...and at the override escape hatch" "$OUT" "=<40-hex"

# Nothing is cloned when the set cannot be resolved: a half-populated workspace
# parent is worse than none, because the next step builds against it.
check "...and no sibling was cloned" \
	"$([[ -e "$WS_PARENT/nim-everywhere" ]] && echo yes || echo no)" "no"

# The commit selection must not be hostage to which sibling happens to be first
# in the list. `isonim` first is exactly the `setup-isonim-siblings` order.
run_step "isonim
nim-acp"
check "an unpinned FIRST sibling does not abort commit selection" "$RC" "1"
contains "...the lock commit is still resolved" "$OUT" "Resolved workspace-lock commit"

# ===========================================================================
# 7. A lock that is genuinely broken must still be refused, loudly and early.
#
# This is the contract that keeps section 6 from being a weakening: exit 5
# (malformed) and exit 6 (contradictory) still stop everything.
# ===========================================================================
mk_manifests "$LOCK_BROKEN"
run_step "nim-acp"
check "a malformed lock still fails the step" "$RC" "1"
contains "...still reported as an unusable lock" "$OUT" "cannot be used"

# The same, but malformed only for a sibling AFTER the probe — the path that
# section 6 deliberately routes around for exit 4 and must not route around for
# exit 5. It is a hard stop, it names the sibling, and it is not filed as a
# membership gap.
mk_manifests "$LOCK_LATE_BAD"
run_step "nim-acp
nim-agents"
check "a lock malformed for a LATER sibling still fails the step" "$RC" "1"
contains "...reported as an unusable lock" "$OUT" "cannot be used"
contains "...naming the sibling it could not answer for" "$OUT" "sibling 'nim-agents'"
lacks "...and not filed as a workspace-membership gap" "$OUT" "pins no revision for these sibling(s)"
check "...and nothing was cloned" \
	"$([[ -e "$WS_PARENT/nim-acp" ]] && echo yes || echo no)" "no"

# ===========================================================================
# 8. No lock at all is still the loud failure it has always been.
# ===========================================================================
mk_manifests ""
run_step "nim-acp"
check "a commit with no lock still fails" "$RC" "1"
contains "...with the no-lock diagnostic" "$OUT" "No workspace lock for codetracer"
lacks "...and never falls back to a branch tip" "$OUT" "(override)"

# ===========================================================================
# 9. An explicit ref that REPLACES a revision the lock pins.
#
# The other direction of the same loss, and the one that used to be completely
# silent. `nim-acp` IS pinned by the lock in this fixture, so `nim-acp=dev`
# un-pins a repo the workspace had pinned: CI keeps passing while it tracks a
# branch tip, and the drift surfaces days later somewhere unrelated.
#
# RED against the unfixed action: `nim-acp=dev` printed
#     nim-acp -> dev (override)
# and a warning that `dev` is not a 40-hex SHA — but nothing anywhere said the
# lock had an answer for `nim-acp`, because with no bare entry in the list the
# manifests repo was never cloned and the lock was never read at all.
# ===========================================================================
mk_manifests "$LOCK_OK"

run_step "nim-acp=dev"
check "an override of a lock pin still succeeds by default (warn)" "$RC" "0"
contains "...raising a warning that says it overrides the lock" "$OUT" \
	"::warning::clone-siblings: 1 sibling entry/entries override a revision the workspace lock already pins"
contains "...naming BOTH revisions" "$OUT" \
	"nim-acp: the lock pins $(sha_of nim-acp) -> this entry requests 'dev'"
contains "...marked UNACKNOWLEDGED in the resolution table" "$OUT" \
	"nim-acp -> dev (override)  <- UNACKNOWLEDGED; the lock pins $(sha_of nim-acp)"
contains "...teaching the pin-preserving fix first" "$OUT" \
	"IF THE PIN IS WHAT YOU WANT (it usually is): delete the '=<ref>'"
contains "...and showing the exact acknowledged spelling" "$OUT" "      nim-acp!=dev"
contains "...with a row on the run's job summary, not only in the raw log" \
	"$(<"$SUMMARY")" "| \`nim-acp\` | \`$(sha_of nim-acp)\` | \`dev\` |"
check "...and the sibling is cloned at the ref the caller asked for" \
	"$("$REAL_GIT" -C "$WS_PARENT/nim-acp" rev-parse HEAD 2>/dev/null)" "$(sha_of nim-acp)"

# A 40-hex override is a real pin, so section 5b asserts it is not warned about
# as "unpinned". It is still an OVERRIDE when it names a different commit than
# the lock — which is the state a real `.github/sibling-repos` in this org is in
# right now, its hand-written SHA having drifted from the lock's. The shape of
# the ref is not what makes an override dangerous; disagreeing with the lock is.
#
# Asserted under `error` so the contract is about the CLASSIFICATION and not
# about what git then does: a SHA from another repository is not fetchable, so
# under `warn` this case would exit 1 from the clone and prove nothing.
run_step "nim-acp=$(sha_of nim-agents)" "error"
check "a 40-hex override that DISAGREES with the lock is still an override" "$RC" "1"
contains "...and is reported as one" "$OUT" \
	"nim-acp: the lock pins $(sha_of nim-acp) -> this entry requests '$(sha_of nim-agents)'"
lacks "...and is not mistaken for the unpinned-ref case" "$OUT" "is not a 40-hex commit SHA"

# The same entry under `on-lock-override: error`.
run_step "nim-acp=dev" "error"
check "on-lock-override=error turns it into a failure" "$RC" "1"
contains "...as an ::error:: annotation" "$OUT" \
	"::error::clone-siblings: 1 sibling entry/entries override a revision the workspace lock already pins"
check "...and nothing is cloned" \
	"$([[ -e "$WS_PARENT/nim-acp" ]] && echo yes || echo no)" "no"

# `name!=ref` acknowledges the override: allowed, labelled, and not warned
# about — under BOTH modes, since the caller has said they mean it.
run_step "nim-acp!=dev" "error"
check "'name!=ref' acknowledges the override even under error mode" "$RC" "0"
lacks "...so no annotation is raised" "$OUT" "::warning::"
contains "...but the table still records that it overrides the lock" "$OUT" \
	"nim-acp -> dev (override)  <- acknowledged with '!='; the lock pins $(sha_of nim-acp)"

# THE NEAR-MISS SHAPE. A list in which EVERY entry carries an explicit ref used
# to skip the manifests clone entirely, so it was the one list this action never
# checked against anything — while being the list most likely to have un-pinned
# something. All four of these are lock-pinned.
FOUR_PINNED=""
for n in "${IN_LOCK[@]}"; do FOUR_PINNED="${FOUR_PINNED}${n}=dev"$'\n'; done
run_step "$FOUR_PINNED" "error"
check "an all-explicit list is checked against the lock too" "$RC" "1"
contains "...reporting all four at once" "$OUT" \
	"clone-siblings: 4 sibling entry/entries override"
for n in "${IN_LOCK[@]}"; do
	contains "...naming $n and the revision it un-pins" "$OUT" \
		"$n: the lock pins $(sha_of "$n")"
done

# Acknowledging one entry must not exempt the others. This is the whole reason
# the acknowledgement is per-entry rather than one action-level switch: the
# near-miss was a single blunt decision applied to a whole list.
run_step "nim-acp!=dev
nim-agents=dev" "error"
check "acknowledging one entry does not exempt another" "$RC" "1"
contains "...only the unacknowledged one is reported" "$OUT" \
	"clone-siblings: 1 sibling entry/entries override"
contains "...and it is the right one" "$OUT" "nim-agents: the lock pins $(sha_of nim-agents)"

# An explicit ref for a repo the lock does NOT pin is the legitimate escape
# hatch. It must not be caught by the override check — a false positive here
# would push callers straight back to `!=` on everything.
run_step "isonim=dev" "error"
check "an explicit ref the lock has no opinion on is not an override" "$RC" "0"
lacks "...so no override is reported" "$OUT" "override a revision the workspace lock"
contains "...it is labelled 'explicit' with the reason" "$OUT" \
	"isonim -> dev (explicit)  <- the lock does not pin this repo"

# An explicit ref equal to the lock's revision overrides nothing.
run_step "nim-acp=$(sha_of nim-acp)" "error"
check "an explicit ref equal to the lock's revision is not an override" "$RC" "0"
contains "...and is labelled as agreeing with the lock" "$OUT" \
	"(explicit-agrees)  <- the same revision the lock pins"

# A trailing `!` on a bare entry is a typo, not a spelling. Left alone it would
# become a clone of a repository named `nim-acp!`.
run_step "nim-acp!"
check "a bare trailing '!' is refused as a typo" "$RC" "1"
contains "...pointing at the spelling that was meant" "$OUT" "'name!=ref' means"

# ===========================================================================
# 10. Losing the lock must not fail a job that never asked it for a revision.
#
# The lock is now read for every list, so a list of purely explicit entries
# reaches the manifests clone where it previously did not. That must not turn a
# missing lock into a new failure for callers who were never resolving from it.
# ===========================================================================
mk_manifests ""
run_step "nim-acp=dev"
check "no lock + an all-explicit list still succeeds" "$RC" "0"
contains "...saying the override check could not run" "$OUT" \
	"this run cannot tell you whether any of those refs is replacing a revision the lock pins"
contains "...and the table says no lock was consulted" "$OUT" \
	"no workspace lock was consulted"
check "...and the sibling is still cloned" \
	"$("$REAL_GIT" -C "$WS_PARENT/nim-acp" rev-parse HEAD 2>/dev/null)" "$(sha_of nim-acp)"

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
	echo "clone-siblings step: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "clone-siblings step: all contracts hold."
