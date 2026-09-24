#!/usr/bin/env bash
#
# publish-workspace-lock-step-test.sh — contract suite for the composite STEP in
# publish-workspace-lock/action.yml.
#
# WHY A SUITE FOR THE STEP
# ------------------------
# `anchor-workspace-lock-test.sh` covers the transform: given a record, does the
# right single field move. It cannot cover the thing that publishes, because
# publishing is a `run:` block inside YAML, and everything that can go wrong
# with an append-only, immutable, concurrently-written store lives there:
# rewriting a published record instead of refusing, losing a push race and
# reporting success, publishing under a SHA that never landed, publishing a
# private layer's sibling set into the public one, or — the failure this whole
# action exists to remove — reporting success while the resolver still cannot
# read the commit.
#
# HOW THE STEP IS RUN
# -------------------
# The step body is `publish-workspace-lock.sh`, a file beside the action, and
# this suite executes THAT FILE: not a copy, not a re-implementation, the same
# bytes the runner executes. It lives outside action.yml because GitHub
# evaluates a composite `run:` body as a template expression and rejects one
# over 21000 characters at parse time -- a failure that lands on every
# consumer's job, not on this repo's CI. The suite asserts that action.yml
# still invokes the script, that no inline `run: |` body has come back, and
# that the script carries no `${{ }}` expression (nothing would expand one).
#
# ONE SHIM, AND ONE DELIBERATE MOCK.
#
#   * The shim is a `git` wrapper on PATH that rewrites
#     `https://github.com/<owner>/<name>` to a local bare repository. It
#     rewrites URLs and nothing else, so every other argument the step passes to
#     git reaches the real git exactly as the step wrote it. Real git, real
#     bares, real pushes, real non-fast-forward rejections, real
#     `merge-base --is-ancestor`, the real `anchor-workspace-lock.sh`, the real
#     `scoped-git-auth.sh`, and the real `resolve-sibling-rev.sh` reading the
#     result.
#
#   * The mock is the CONCURRENT PUBLISHER. `$RACE_MARKER` makes the shim, on
#     the step's first `git push`, first land an unrelated lock record on the
#     manifests bare from a side clone. That is a mock in the sense that this
#     suite chooses the moment; it is not a mock of the mechanism, because what
#     the step then meets is a real `[rejected] ... fetch first` from a real
#     git. It is justified because the contract under test — "two merges landing
#     seconds apart both end up locked" — is a statement about an interleaving,
#     and an interleaving that is left to chance is a contract that is not
#     tested. There is no other way to make git lose a race on demand.
#
# MUTATION-VERIFIED. Every contract below was observed to FAIL against a
# deliberately broken step before being accepted; see the mutation table in the
# change that introduced this file.
#
# Run: bash publish-workspace-lock/publish-workspace-lock-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ACTION="$HERE/action.yml"
RESOLVER="$ROOT/clone-siblings/resolve-sibling-rev.sh"

[[ -f $ACTION ]] || {
	echo "publish-workspace-lock-step-test: cannot find $ACTION" >&2
	exit 2
}
[[ -f $RESOLVER ]] || {
	echo "publish-workspace-lock-step-test: cannot find $RESOLVER" >&2
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
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# 1. Extract the step body from action.yml.
# ---------------------------------------------------------------------------
# The step body is a FILE beside the action, not a `run: |` block: GitHub
# evaluates a composite run body as a template expression and rejects one over
# 21000 characters at parse time, which fails every consumer's job before its
# first step. So this suite executes the real script -- the same bytes the
# runner executes -- and asserts only that action.yml still calls it.
STEP="$HERE/publish-workspace-lock.sh"

[[ -f $STEP ]] || {
	echo "publish-workspace-lock-step-test: cannot find $STEP" >&2
	exit 2
}

WIRING='run: bash "${GITHUB_ACTION_PATH}/publish-workspace-lock.sh"'
case "$(<"$ACTION")" in
*"$WIRING"*) : ;;
*)
	echo "publish-workspace-lock-step-test: $ACTION no longer invokes the step script." >&2
	echo "  expected a line containing -> $WIRING" >&2
	exit 2
	;;
esac

# A `run: |` body that came back would be untested by this suite AND would be
# back under the template-length budget that moved it out here in the first
# place.
case "$(<"$ACTION")" in
*$'\n      run: |'*)
	echo "publish-workspace-lock-step-test: $ACTION has grown an inline run: block again;" >&2
	echo "  the step body belongs in publish-workspace-lock.sh (see its header)." >&2
	exit 2
	;;
esac

bash -n "$STEP" || {
	echo "publish-workspace-lock-step-test: the step script is not valid bash (see above)." >&2
	exit 2
}

# The `${{ }}` guard. The script carries none -- nothing would expand one, and
# every value arrives through the step's `env:` block, which the runner
# evaluates and this suite sets directly.
case "$(<"$STEP")" in
*'${{'*)
	echo "publish-workspace-lock-step-test: the step script contains a \${{ }} expression, which nothing expands:" >&2
	while IFS= read -r l; do
		case "$l" in *'${{'*) echo "  $l" >&2 ;; esac
	done <"$STEP"
	exit 2
	;;
esac

# ---------------------------------------------------------------------------
# 2. Fixtures.
# ---------------------------------------------------------------------------
SRV="$TMPROOT/srv"
mkdir -p "$SRV/metacraft-labs" "$SRV/metacraft-private" "$TMPROOT/bin"

REAL_GIT="$(command -v git)"
RACE_MARKER="$TMPROOT/race-fired"
RACE_INJECT="$TMPROOT/bin/race-inject.sh"

cat >"$TMPROOT/bin/git" <<SHIM
#!/usr/bin/env bash
# URL-only rewrite: https://github.com/<x> -> file://$SRV/<x>. Every other
# argument is passed through untouched.
#
# Plus the concurrent-publisher mock: when RACE_TRIGGER is set, the FIRST push
# this shim sees lands somebody else's lock record on the manifests bare before
# the step's own push is attempted, so the step meets a genuine rejection.
args=()
is_push=0
for a in "\$@"; do
  [ "\$a" = "push" ] && is_push=1
  case "\$a" in
    https://github.com/*) args+=("file://$SRV/\${a#https://github.com/}") ;;
    *) args+=("\$a") ;;
  esac
done
if [ -n "\${RACE_TRIGGER:-}" ] && [ "\$is_push" = "1" ] && [ ! -e "$RACE_MARKER" ]; then
  : >"$RACE_MARKER"
  bash "$RACE_INJECT" >/dev/null 2>&1
fi
exec "$REAL_GIT" "\${args[@]}"
SHIM
chmod +x "$TMPROOT/bin/git"

git_q() { "$REAL_GIT" "$@" >/dev/null 2>&1; }
gitc() { "$REAL_GIT" -c user.name=CI -c user.email=ci@local "$@"; }

MANIFESTS_BARE="$SRV/metacraft-labs/metacraft-manifests.git"
PRIVATE_BARE="$SRV/metacraft-private/metacraft-manifests-private.git"
SELF_BARE="$SRV/metacraft-labs/codetracer.git"

# The concurrent publisher: a real clone, a real disjoint addition, a real push.
cat >"$RACE_INJECT" <<INJECT
#!/usr/bin/env bash
set -e
d="\$(mktemp -d)"
"$REAL_GIT" clone --quiet --branch latest "$MANIFESTS_BARE" "\$d"
mkdir -p "\$d/locks/codetracer/codetracer"
printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nproject = "codetracer"\ncreated_at = "x"\n\n[[repo]]\nname = "codetracer"\npath = "codetracer"\nremote = "metacraft-labs"\nrevision = "9999999999999999999999999999999999999999"\n' \
  >"\$d/locks/codetracer/codetracer/9999999999999999999999999999999999999999.toml"
"$REAL_GIT" -C "\$d" add -A
"$REAL_GIT" -C "\$d" -c user.name=Other -c user.email=other@local commit --quiet --no-gpg-sign -m "Publish 1 workspace lock entry"
"$REAL_GIT" -C "\$d" push --quiet origin HEAD:latest
rm -rf "\$d"
INJECT
chmod +x "$RACE_INJECT"

# --- the repo under test: a mainline branch and a PR branch off it ----------
SELF_WORK="$TMPROOT/build/codetracer"
mkdir -p "$SELF_WORK"
git_q init --bare -b dev "$SELF_BARE"
# Exercise the step's primary, blobless clone path against this server.
git_q -C "$SELF_BARE" config uploadpack.allowFilter true
git_q -C "$SELF_WORK" init -b dev .
printf 'base\n' >"$SELF_WORK/README"
git_q -C "$SELF_WORK" add README
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m base
BASE_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"

git_q -C "$SELF_WORK" checkout -b feature
printf 'pr\n' >"$SELF_WORK/README"
git_q -C "$SELF_WORK" add README
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "the PR head"
HEAD_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"

# The mainline commit GitHub creates on merge. A REBASE/SQUASH merge — the
# strategy codetracer actually uses — produces a brand-new single-parent commit
# whose SHA nothing has ever locked, which is exactly the gap under test.
git_q -C "$SELF_WORK" checkout dev
printf 'pr\n' >"$SELF_WORK/README"
git_q -C "$SELF_WORK" add README
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "the merged mainline commit"
MERGE_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"

# A commit that never landed on dev: what an OPEN pull request's
# merge_commit_sha names.
git_q -C "$SELF_WORK" checkout -b stray "$BASE_SHA"
printf 'stray\n' >"$SELF_WORK/README"
git_q -C "$SELF_WORK" add README
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "a test merge that never landed"
STRAY_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"
git_q -C "$SELF_WORK" checkout dev
git_q -C "$SELF_WORK" push "$SELF_BARE" dev feature stray

SIB_A="1111111111111111111111111111111111111111"
SIB_B="2222222222222222222222222222222222222222"

lock_body() { # <self-revision> [<project>]
	printf 'schema = "reprobuild.workspace.lock.v1"\n\n'
	printf '[lock]\nproject = "%s"\ncreated_at = "2026-08-24T21:44:02Z"\ncreated_by = "repro workspace lock"\n\n' "${2:-codetracer}"
	printf '[[repo]]\nname = "nim-agents"\npath = "nim-agents"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "dev"\n\n' "$SIB_A"
	printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "feature"\n\n' "$1"
	printf '[[repo]]\nname = "infra"\npath = "infra"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "live"\n' "$SIB_B"
}

MAN_WORK="$TMPROOT/build/manifests"
mk_manifests() { # [<extra-setup-fn>]
	rm -rf "$MANIFESTS_BARE" "$MAN_WORK" "$RACE_MARKER"
	git_q init --bare -b latest "$MANIFESTS_BARE"
	mkdir -p "$MAN_WORK/locks/codetracer/codetracer"
	git_q -C "$MAN_WORK" init -b latest .
	lock_body "$HEAD_SHA" >"$MAN_WORK/locks/codetracer/codetracer/$HEAD_SHA.toml"
	[[ -n ${1:-} ]] && "$1"
	git_q -C "$MAN_WORK" add -A
	gitc -C "$MAN_WORK" commit --quiet --no-gpg-sign -m locks
	git_q -C "$MAN_WORK" push "$MANIFESTS_BARE" latest
}

mk_private() { # <populate?>
	rm -rf "$PRIVATE_BARE" "$TMPROOT/build/private"
	git_q init --bare -b latest "$PRIVATE_BARE"
	mkdir -p "$TMPROOT/build/private"
	git_q -C "$TMPROOT/build/private" init -b latest .
	if [[ ${1:-} == populate ]]; then
		mkdir -p "$TMPROOT/build/private/locks/codetracer/codetracer"
		lock_body "$HEAD_SHA" >"$TMPROOT/build/private/locks/codetracer/codetracer/$HEAD_SHA.toml"
	else
		printf 'placeholder\n' >"$TMPROOT/build/private/.keep"
	fi
	git_q -C "$TMPROOT/build/private" add -A
	gitc -C "$TMPROOT/build/private" commit --quiet --no-gpg-sign -m locks
	git_q -C "$TMPROOT/build/private" push "$PRIVATE_BARE" latest
}

# ---------------------------------------------------------------------------
# 3. The driver.
# ---------------------------------------------------------------------------
OUT=""
RC=0
run_step() { # [VAR=VALUE ...] overrides via the environment below
	rm -rf "$TMPROOT/runner-temp"
	mkdir -p "$TMPROOT/runner-temp"
	OUT="$(
		PATH="$TMPROOT/bin:$PATH" \
			GH_TOKEN="${GH_TOKEN_IN-ci-token}" \
			INPUT_REPO="${INPUT_REPO:-}" \
			DEFAULT_REPO="metacraft-labs/codetracer" \
			SOURCE_SHA="${SOURCE_SHA:-$HEAD_SHA}" \
			TARGET_SHA="${TARGET_SHA:-$MERGE_SHA}" \
			BASE_REF="${BASE_REF:-dev}" \
			PROVENANCE="${PROVENANCE:-pull request #652}" \
			MANIFESTS_REPO="metacraft-labs/metacraft-manifests" \
			INPUT_MANIFESTS_REF="latest" \
			PRIVATE_MANIFESTS_REPO="${PRIVATE_REPO_IN:-}" \
			INPUT_PRIVATE_MANIFESTS_REF="" \
			JOB_TOKEN_OWNERS="${JOB_OWNERS_IN:-metacraft-labs}" \
			COMMITTER_NAME="metacraft-ci" \
			COMMITTER_EMAIL="ci@metacraft-labs.com" \
			GIT_AUTH_DIR="$ROOT/git-auth" \
			ANCHOR="$HERE/anchor-workspace-lock.sh" \
			RUNNER_TEMP="$TMPROOT/runner-temp" \
			RACE_TRIGGER="${RACE_TRIGGER:-}" \
			bash "$STEP" 2>&1
	)"
	RC=$?
	if [[ -n ${SHOW_STEP_OUTPUT:-} ]]; then
		echo "--- step rc=$RC ---"
		echo "$OUT"
		echo "--- end ---"
	fi
}

# A fresh read of what the manifests bare actually holds now. Assertions are
# made against the SERVER, not against the step's own working copy: a step that
# writes a perfect record and never pushes it looks identical from the inside.
CHECKOUT="$TMPROOT/verify"
refresh_checkout() { # [<bare>]
	rm -rf "$CHECKOUT"
	git_q clone --branch latest "${1:-$MANIFESTS_BARE}" "$CHECKOUT"
}
remote_tip() { "$REAL_GIT" -C "$MANIFESTS_BARE" rev-parse latest; }
remote_commits() { "$REAL_GIT" -C "$MANIFESTS_BARE" rev-list --count latest; }

# Sets RESOLVE_RC and RESOLVE_OUT rather than printing: the exit code IS the
# contract in half the cases below, and a command substitution would run the
# resolver in a subshell where that code cannot be observed.
RESOLVE_RC=0
RESOLVE_OUT=""
resolve() { # <sibling> <sha>
	RESOLVE_RC=0
	RESOLVE_OUT="$(bash "$RESOLVER" --repo codetracer --sibling "$1" \
		--manifest-dir "$CHECKOUT" --sha "$2" --no-walk 2>&1)" || RESOLVE_RC=$?
}

# ===========================================================================
# 0. THE DEFECT, REPRODUCED IN THIS HARNESS.
#
# Before anything is published: the PR head resolves, the mainline commit that
# landed it does not, and the resolver says so with the exit code the action
# then reports as "No workspace lock for codetracer". Every contract below is
# only meaningful because this one holds first.
# ===========================================================================
mk_manifests
refresh_checkout
resolve nim-agents "$HEAD_SHA"
GOT="$RESOLVE_OUT"
check "reproduction: the PR head IS locked (resolver exit 0)" "$RESOLVE_RC" "0"
check "reproduction: ...and answers with the pinned sibling revision" "$GOT" "$SIB_A"
resolve nim-agents "$MERGE_SHA"
GOT="$RESOLVE_OUT"
check "reproduction: the mainline commit that landed it is NOT (resolver exit 3)" "$RESOLVE_RC" "3"
contains "reproduction: ...reported as a missing lock, by name" "$GOT" "no workspace lock found for codetracer"

# ===========================================================================
# 1. THE FIX, END TO END.
# ===========================================================================
BEFORE_COMMITS="$(remote_commits)"
run_step
check "publish: the step succeeds" "$RC" "0"
contains "publish: it proves the target landed before writing anything" "$OUT" "Proven: $MERGE_SHA is an ancestor of metacraft-labs/codetracer@dev"
contains "publish: and says what it published, where" "$OUT" "Published locks/codetracer/codetracer/$MERGE_SHA.toml to metacraft-labs/metacraft-manifests@latest"

refresh_checkout
check "publish: the record is on the SERVER, not merely in the step's checkout" \
	"$(test -f "$CHECKOUT/locks/codetracer/codetracer/$MERGE_SHA.toml" && echo yes || echo no)" "yes"
check "publish: exactly one commit was added to the manifests branch" \
	"$(($(remote_commits) - BEFORE_COMMITS))" "1"

resolve nim-agents "$MERGE_SHA"
GOT="$RESOLVE_OUT"
check "publish: the mainline commit now resolves (resolver exit 0)" "$RESOLVE_RC" "0"
check "publish: ...to the revision the PR head pinned" "$GOT" "$SIB_A"
resolve infra "$MERGE_SHA"
GOT="$RESOLVE_OUT"
check "publish: ...for every sibling in the record, not just the first" "$GOT" "$SIB_B"

# The recorded sibling set must be the PR HEAD's, verbatim. The one line that
# may differ is the record's own coordinate.
DIFF="$(diff "$CHECKOUT/locks/codetracer/codetracer/$HEAD_SHA.toml" \
	"$CHECKOUT/locks/codetracer/codetracer/$MERGE_SHA.toml")"
check "publish: the published record differs from the PR head's in exactly one line" \
	"$(printf '%s\n' "$DIFF" | grep -c '^[<>]')" "2"
contains "publish: and that line is the repo's own revision, now the mainline commit" \
	"$DIFF" "> revision = \"$MERGE_SHA\""

LOG="$("$REAL_GIT" -C "$CHECKOUT" log -1 --format='%s%n%b')"
contains "publish: the commit message names the record count and the commit locked" \
	"$LOG" "Publish 1 workspace lock entry for codetracer@$MERGE_SHA"
contains "publish: provenance lives in the message, where it is not a schema change" \
	"$LOG" "Landed by pull request #652."
contains "publish: ...along with the record it was re-anchored from" \
	"$LOG" "Re-anchored from the lock published for codetracer@$HEAD_SHA."

# ===========================================================================
# 2. IDEMPOTENCY. A re-run — a re-dispatched workflow, a retried job — must be a
#    no-op, not a second commit and not a failure.
# ===========================================================================
BEFORE_TIP="$(remote_tip)"
run_step
check "idempotent: a second run succeeds" "$RC" "0"
check "idempotent: ...and adds no commit" "$(remote_tip)" "$BEFORE_TIP"
contains "idempotent: ...and says the record was already published" "$OUT" "Already published"

# ===========================================================================
# 2b. IDEMPOTENCY WITHOUT `cmp`. The comparison that decides "already
#     published" must not depend on a tool the runner may not have.
#
#     This is a regression test for a real outage, not a defensive flourish.
#     The check was `cmp -s`, whose non-zero exit means "differ" OR "not on
#     PATH", and the step read the second as the first: codetracer-launcher run
#     34844401895 printed `line 198: cmp: command not found` and then announced
#     "A DIFFERENT lock record is already published" against a destination whose
#     bytes were identical. `cmp` comes from diffutils, which `ubuntu-latest`
#     carries and a self-hosted nixos runner's PATH need not — and a PRIVATE
#     repo has to use a self-hosted runner here, because a hosted job on such a
#     repo does not start at all. So the dependency was missing exactly where
#     this action is load-bearing, and it failed toward the louder wrong answer:
#     a retried job claiming an immutability violation.
#
#     The shim below reproduces what the step actually observed — a `cmp` that
#     exits 127 having compared nothing. A step that still consults `cmp` fails
#     this case; one that compares the bytes itself does not.
# ===========================================================================
mk_manifests
run_step   # publish it once, so the destination exists
check "no-cmp: the record is published first" "$RC" "0"
BEFORE_TIP="$(remote_tip)"

cat >"$TMPROOT/bin/cmp" <<'NOCMP'
#!/usr/bin/env bash
echo "cmp: command not found" >&2
exit 127
NOCMP
chmod +x "$TMPROOT/bin/cmp"

run_step
rm -f "$TMPROOT/bin/cmp"

check "no-cmp: a re-run with cmp unavailable still succeeds" "$RC" "0"
check "no-cmp: ...and still adds no commit" "$(remote_tip)" "$BEFORE_TIP"
contains "no-cmp: ...and still recognises the published record" "$OUT" "Already published"
lacks "no-cmp: ...and never claims a disagreement it did not measure" 	"$OUT" "Published records are immutable and this one is not rewritten"
lacks "no-cmp: ...because it does not consult cmp at all" "$OUT" "cmp: command not found"

# ===========================================================================
# 3. IMMUTABILITY. A published record is never rewritten — not even by this
#    action, which is the only thing in CI that can write to the store.
# ===========================================================================
plant_conflicting() {
	mkdir -p "$MAN_WORK/locks/codetracer/codetracer"
	{
		printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nproject = "codetracer"\ncreated_at = "x"\n\n'
		printf '[[repo]]\nname = "nim-agents"\npath = "nim-agents"\nremote = "m"\nrevision = "3333333333333333333333333333333333333333"\n\n'
		printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nremote = "m"\nrevision = "%s"\n' "$MERGE_SHA"
	} >"$MAN_WORK/locks/codetracer/codetracer/$MERGE_SHA.toml"
}
mk_manifests plant_conflicting
BEFORE_TIP="$(remote_tip)"
run_step
check "immutable: a destination that already differs is a hard failure" "$RC" "1"
contains "immutable: ...named as immutability, not as a merge conflict" "$OUT" "Published records are immutable and this one is not rewritten"
check "immutable: ...and the manifests branch is untouched" "$(remote_tip)" "$BEFORE_TIP"
refresh_checkout
check "immutable: ...and the existing record still holds its original bytes" \
	"$(grep -c '3333333333333333333333333333333333333333' "$CHECKOUT/locks/codetracer/codetracer/$MERGE_SHA.toml")" "1"

# ===========================================================================
# 4. NO SOURCE, NO INVENTION. The one thing that must never happen here is a
#    lock conjured for a commit nobody locked.
# ===========================================================================
mk_manifests
BEFORE_TIP="$(remote_tip)"
SOURCE_SHA="$STRAY_SHA" run_step
check "no source: a source commit with no published lock fails the step" "$RC" "1"
contains "no source: ...and says it will not invent one" "$OUT" "will not invent one"
contains "no source: ...with the remedy that actually produces the record" "$OUT" "push it once from a workspace"
# The dominant cause is not a fork and not --no-verify: it is a checkout with no
# managed hooks at all. Over the last 24 merged pull requests only 4 of
# codetracer's heads and 3 of infra's were locked, so a remedy that names only
# the exotic cases sends most readers looking in the wrong place.
contains "no source: ...naming the hook-coverage cause, not only the exotic ones" "$OUT" "repro hooks ensure --vcs"
contains "no source: ...and the dispatch that re-runs it afterwards" "$OUT" "workflow_dispatch, with source-sha="
check "no source: ...and nothing is pushed" "$(remote_tip)" "$BEFORE_TIP"
unset SOURCE_SHA

# ===========================================================================
# 5. THE TARGET MUST HAVE LANDED. An open pull request's merge_commit_sha names
#    a throwaway test merge; a record filed under it is unreachable garbage in
#    an append-only store, and mainline stays unlocked behind a green job.
# ===========================================================================
BEFORE_TIP="$(remote_tip)"
TARGET_SHA="$STRAY_SHA" run_step
check "ancestry: a target that never landed on the base branch fails the step" "$RC" "1"
contains "ancestry: ...named for what it is" "$OUT" "is not an ancestor of metacraft-labs/codetracer@dev"
check "ancestry: ...and nothing is pushed" "$(remote_tip)" "$BEFORE_TIP"
lacks "ancestry: ...and the proof never claimed to have succeeded" "$OUT" "Proven:"
unset TARGET_SHA

# ===========================================================================
# 6. SHAPE REFUSALS. Every value below is substituted into a git command line or
#    becomes a published FILENAME. `git fetch` parses options after the remote,
#    so `--upload-pack=<cmd>` in a ref runs `<cmd>` on the runner.
# ===========================================================================
BEFORE_TIP="$(remote_tip)"
TARGET_SHA="dev" run_step
check "shape: a target revision that is not a SHA is refused" "$RC" "1"
contains "shape: ...by shape, before anything is fetched" "$OUT" "target-sha must be a 40-character lowercase hex commit SHA"
lacks "shape: ...so no clone was attempted" "$OUT" "Fetching metacraft-labs/codetracer"
unset TARGET_SHA

TARGET_SHA="$HEAD_SHA" run_step
check "shape: re-anchoring a commit onto itself is refused" "$RC" "1"
contains "shape: ...as the no-op it would be" "$OUT" "needs no re-anchoring"
unset TARGET_SHA

BASE_REF="--upload-pack=touch /tmp/pwned" run_step
check "shape: a base ref carrying a git option is refused" "$RC" "1"
contains "shape: ...by character class, not by blocklist" "$OUT" "base-ref must be a branch name, not starting with '-'"
# A non-SHA base ref also makes `git clone --branch` exit 1, so "the step
# failed" proves nothing on its own. What must hold is that the value never
# reached git at all — `git clone` parses options after the URL, and
# `--upload-pack=<cmd>` runs `<cmd>` on the runner.
lacks "shape: ...before the value reaches a git command line" "$OUT" "Fetching metacraft-labs/codetracer"
unset BASE_REF

GH_TOKEN_IN="" run_step
check "shape: an empty token is refused up front" "$RC" "1"
contains "shape: ...because this action must PUSH" "$OUT" "there is no unauthenticated path to that"
unset GH_TOKEN_IN
check "shape: none of the refusals above touched the manifests branch" "$(remote_tip)" "$BEFORE_TIP"

# ===========================================================================
# 7. A PARTICIPATION RECORD IS NOT A LOCK. Routed locking mode writes a
#    per-repo record that pins only its own repo. Re-filing it would publish a
#    record the resolver reads as UNLOCKED — a green job and an unchanged
#    symptom.
# ===========================================================================
plant_participation() {
	rm -f "$MAN_WORK/locks/codetracer/codetracer/$HEAD_SHA.toml"
	printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nrevision = "%s"\n' "$HEAD_SHA" \
		>"$MAN_WORK/locks/codetracer/codetracer/$HEAD_SHA.toml"
}
mk_manifests plant_participation
BEFORE_TIP="$(remote_tip)"
run_step
check "participation: a routed participation record is not re-anchored" "$RC" "1"
contains "participation: ...named as what it is" "$OUT" "PARTICIPATION RECORD"
check "participation: ...and nothing is pushed" "$(remote_tip)" "$BEFORE_TIP"

# ===========================================================================
# 8. THE PUSH RACE. Two merges landing seconds apart must BOTH end up locked.
# ===========================================================================
mk_manifests
BEFORE_COMMITS="$(remote_commits)"
RACE_TRIGGER=1 run_step
check "race: the step succeeds after losing a push race" "$RC" "0"
contains "race: ...and says it re-applied rather than reporting success blindly" "$OUT" "Another publisher moved"
refresh_checkout
check "race: our record landed" \
	"$(test -f "$CHECKOUT/locks/codetracer/codetracer/$MERGE_SHA.toml" && echo yes || echo no)" "yes"
check "race: the other publisher's record survived — no force, no clobber" \
	"$(test -f "$CHECKOUT/locks/codetracer/codetracer/9999999999999999999999999999999999999999.toml" && echo yes || echo no)" "yes"
check "race: both publishers' commits are on the branch" \
	"$(($(remote_commits) - BEFORE_COMMITS))" "2"
resolve nim-agents "$MERGE_SHA"
GOT="$RESOLVE_OUT"
check "race: and the mainline commit resolves afterwards" "$RESOLVE_RC" "0"

# ===========================================================================
# 9. LAYERS. A repo whose lock lives in the access-controlled layer gets its
#    re-anchored record THERE. Demoting it into the public layer would publish
#    a private workspace's sibling set to everyone, and would be read at a
#    different precedence besides.
# ===========================================================================
mk_manifests_empty() {
	rm -rf "$MANIFESTS_BARE" "$MAN_WORK" "$RACE_MARKER"
	git_q init --bare -b latest "$MANIFESTS_BARE"
	mkdir -p "$MAN_WORK/locks/codetracer"
	git_q -C "$MAN_WORK" init -b latest .
	printf 'placeholder\n' >"$MAN_WORK/locks/codetracer/.keep"
	git_q -C "$MAN_WORK" add -A
	gitc -C "$MAN_WORK" commit --quiet --no-gpg-sign -m locks
	git_q -C "$MAN_WORK" push "$MANIFESTS_BARE" latest
}
mk_manifests_empty
mk_private populate
PUBLIC_TIP="$(remote_tip)"

# First: a private layer whose OWNER is outside the job's token scope. The
# clones would 404 as "no such repository" halfway through a publish; saying so
# here, by name, is the same check clone-siblings makes on the read side.
PRIVATE_REPO_IN="metacraft-private/metacraft-manifests-private" run_step
check "layers: a private layer outside the token's scope is refused" "$RC" "1"
contains "layers: ...naming the owner that is not covered" "$OUT" "metacraft-private"
check "layers: ...before touching the public layer" "$(remote_tip)" "$PUBLIC_TIP"

JOB_OWNERS_IN="metacraft-labs metacraft-private"
PRIVATE_REPO_IN="metacraft-private/metacraft-manifests-private" run_step
check "layers: the private layer's lock is re-anchored" "$RC" "0"
contains "layers: ...and published to the private layer" "$OUT" "to metacraft-private/metacraft-manifests-private@latest"
check "layers: the public layer is left alone — no demotion" "$(remote_tip)" "$PUBLIC_TIP"
refresh_checkout "$PRIVATE_BARE"
check "layers: the record is on the private server" \
	"$(test -f "$CHECKOUT/locks/codetracer/codetracer/$MERGE_SHA.toml" && echo yes || echo no)" "yes"
unset PRIVATE_REPO_IN JOB_OWNERS_IN

# ===========================================================================
# 10. SEVERAL PROJECTS, ONE COMMIT. A repo commit may be locked under more than
#     one workspace project (codetracer's canonical project plus a feature
#     workspace such as `dev`). Re-anchoring one of them and dropping the other
#     would silently change which project the resolver's --prefer-project
#     tie-break lands on.
# ===========================================================================
plant_second_project() {
	mkdir -p "$MAN_WORK/locks/dev/codetracer"
	lock_body "$HEAD_SHA" dev >"$MAN_WORK/locks/dev/codetracer/$HEAD_SHA.toml"
}
mk_manifests plant_second_project
run_step
check "projects: the step succeeds with the commit locked under two projects" "$RC" "0"
contains "projects: the canonical project's record is published" "$OUT" "Published locks/codetracer/codetracer/$MERGE_SHA.toml"
contains "projects: the second project's record is published too" "$OUT" "Published locks/dev/codetracer/$MERGE_SHA.toml"
contains "projects: ...as one commit naming both" "$OUT" "2 record(s) published"

# ===========================================================================
# 11. THE CARRY MUST NOT OUTRUN ITS EVIDENCE.
#
#     The `push` wiring carries `github.event.before`'s record onto
#     `github.sha`, so the sibling set recorded for a mainline commit was
#     observed at an ancestor and copied forward link by link. For a commit
#     that changed nothing about the workspace that is the point — it is what
#     keeps `clone-siblings` able to answer at all. For a commit that BUMPED A
#     SIBLING the carried set is not merely stale, it CONTRADICTS the commit it
#     is filed under; and because publication is additions-only and records are
#     immutable, that commit can never afterwards record its real state.
#
#     The repo's own committed `repro.lock` is its declaration of the
#     composition, so "did the composition change across this range" is
#     answerable from the repo's history without observing a workspace. This
#     section pins all three outcomes: a carry across an unchanged declaration
#     proceeds, a carry across a changed one is refused with nothing published,
#     and a backfill whose SHAs have no ancestry is not caught by the guard.
# ===========================================================================
git_q -C "$SELF_WORK" checkout dev
printf 'schema = "reprobuild.workspace.lock.v1"\nrevision = "%s"\n' "$SIB_A" \
	>"$SELF_WORK/repro.lock"
git_q -C "$SELF_WORK" add repro.lock
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "declare the composition"
LOCKED_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"

printf 'unrelated\n' >"$SELF_WORK/README"
git_q -C "$SELF_WORK" add README
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "a commit that moves no sibling"
QUIET_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"

printf 'schema = "reprobuild.workspace.lock.v1"\nrevision = "%s"\n' "$SIB_B" \
	>"$SELF_WORK/repro.lock"
git_q -C "$SELF_WORK" add repro.lock
gitc -C "$SELF_WORK" commit --quiet --no-gpg-sign -m "bump a sibling"
BUMP_SHA="$("$REAL_GIT" -C "$SELF_WORK" rev-parse HEAD)"
git_q -C "$SELF_WORK" push "$SELF_BARE" dev

mk_manifests

# The seed hop. `$HEAD_SHA` is the PULL REQUEST head and `$LOCKED_SHA` is on
# the mainline, so neither is an ancestor of the other: this is the
# workflow_dispatch backfill shape, where an operator states both SHAs, and the
# guard must say it could not evaluate the span rather than inventing a verdict
# about it.
SOURCE_SHA="$HEAD_SHA" TARGET_SHA="$LOCKED_SHA" run_step
check "carry: a backfill whose SHAs have no ancestry still publishes" "$RC" "0"
contains "carry: ...and says the span was not evaluated rather than guessing" \
	"$OUT" "Carry span not evaluated"
unset SOURCE_SHA TARGET_SHA

# A real forward carry across a commit that moved no sibling. This is the case
# the chain exists for, and it must keep working.
SOURCE_SHA="$LOCKED_SHA" TARGET_SHA="$QUIET_SHA" run_step
check "carry: a commit that moved no sibling is carried" "$RC" "0"
contains "carry: ...and the unchanged declaration is stated, not assumed" \
	"$OUT" "Carry checked: repro.lock is unchanged"
contains "carry: ...and the record is published under the new commit" \
	"$OUT" "Published locks/codetracer/codetracer/$QUIET_SHA.toml"
unset SOURCE_SHA TARGET_SHA

# The forward carry across a commit that DID move a sibling. `$QUIET_SHA` is
# locked by the hop above, so the source record exists and everything else
# about this run is identical to the one that just succeeded — the only
# difference is that the repo's own declaration changed in between.
BEFORE_TIP="$(remote_tip)"
SOURCE_SHA="$QUIET_SHA" TARGET_SHA="$BUMP_SHA" run_step
if [[ $RC -ne 0 ]]; then ok "carry: a commit that bumped a sibling is refused"; else
	bad "carry: a commit that bumped a sibling is refused" "step exited 0"
fi
contains "carry: ...naming the declaration that moved" "$OUT" "repro.lock differs between"
contains "carry: ...and both commits it moved between" "$OUT" "$QUIET_SHA and $BUMP_SHA"
contains "carry: ...and saying the set would contradict the commit" \
	"$OUT" "contradicts the commit it names"
contains "carry: ...and naming a remedy that OBSERVES rather than carries" \
	"$OUT" "refresh-workspace-lock"
check "carry: ...with the manifests branch left where it was" "$(remote_tip)" "$BEFORE_TIP"
refresh_checkout
if [[ -e "$CHECKOUT/locks/codetracer/codetracer/$BUMP_SHA.toml" ]]; then
	bad "carry: ...and no record filed under the bumped commit" "a record was published"
else
	ok "carry: ...and no record filed under the bumped commit"
fi
unset SOURCE_SHA TARGET_SHA

# ===========================================================================
# 12. AN OBSERVED COMMIT IS NOT CARRIED ONTO.
#
#     A push from a workspace whose pre-push gate publishes records the target
#     BEFORE this job runs. A carried record ADDED beside that observation at a
#     different path does not confirm it -- it competes with it, and the
#     resolver picks by glob order (every `.xml` before any `.toml`, first
#     project wins), so a carried legacy `locks/dev/.../<sha>.xml` SHADOWS the
#     observed `locks/codetracer/.../<sha>.toml`. That is how
#     codetracer-python-recorder@377e03bb and codetracer-ruby-recorder@8bacef81
#     came to resolve a 2026-09-09 composition no workspace had observed since.
#
#     Pinned here: (a) the shadow itself, through the real resolver, so the
#     premise is measured rather than asserted; (b) the carry adds nothing to an
#     observed commit and the observation is what resolves; (c) a target whose
#     only record is a PARTICIPATION record is still unlocked and IS carried;
#     (d) a same-path disagreement is still the hard immutability failure of
#     contract 3 -- the guard skips additions, it does not swallow conflicts.
# ===========================================================================
SIB_OBS="4444444444444444444444444444444444444444"
xml_body() { # <self-revision>
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n'
	printf '  <remote name="metacraft-labs" fetch="https://github.com/metacraft-labs"/>\n'
	printf '  <project name="nim-agents" path="nim-agents" remote="metacraft-labs" revision="%s" upstream="dev" dest-branch="dev"/>\n' "$SIB_A"
	printf '  <project name="codetracer" path="codetracer" remote="metacraft-labs" revision="%s" upstream="dev" dest-branch="dev"/>\n' "$1"
	printf '</manifest>\n'
}
observed_body() { # the pre-push gate's record for the MERGE commit
	lock_body "$MERGE_SHA" | sed "s/$SIB_A/$SIB_OBS/"
}
# Source: legacy XML only (the python/ruby shape). Target: an observed TOML.
plant_legacy_source_and_observed_target() {
	rm -f "$MAN_WORK/locks/codetracer/codetracer/$HEAD_SHA.toml"
	mkdir -p "$MAN_WORK/locks/dev/codetracer"
	xml_body "$HEAD_SHA" >"$MAN_WORK/locks/dev/codetracer/$HEAD_SHA.xml"
	observed_body >"$MAN_WORK/locks/codetracer/codetracer/$MERGE_SHA.toml"
}

# The resolver's preferred project defaults to the repo's own NAME. Here the
# repo is `codetracer`, which is also a project, so the default would pick the
# observation for the wrong reason. The repos this bit are recorders, whose
# names are no project; `--prefer-project` set to such a name reproduces
# exactly what `clone-siblings` (which passes none) does for them.
resolve_as_recorder() { # <sibling> <sha>
	RESOLVE_RC=0
	RESOLVE_OUT="$(bash "$RESOLVER" --repo codetracer --sibling "$1" \
		--manifest-dir "$CHECKOUT" --sha "$2" --no-walk \
		--prefer-project codetracer-python-recorder 2>&1)" || RESOLVE_RC=$?
}

# (a) the premise: with BOTH present for one commit, the resolver answers from
#     the legacy XML, not from the observation.
mk_manifests plant_legacy_source_and_observed_target
refresh_checkout
mkdir -p "$CHECKOUT/locks/dev/codetracer"
xml_body "$MERGE_SHA" >"$CHECKOUT/locks/dev/codetracer/$MERGE_SHA.xml"
resolve_as_recorder nim-agents "$MERGE_SHA"
check "observed: premise -- a legacy .xml beside an observed .toml shadows it in the resolver" \
	"$RESOLVE_OUT" "$SIB_A"

# (b) the carry adds nothing, and the observation is what resolves.
mk_manifests plant_legacy_source_and_observed_target
BEFORE_TIP="$(remote_tip)"
run_step
check "observed: a carry onto an already-recorded commit succeeds" "$RC" "0"
contains "observed: ...and says why it adds nothing" "$OUT" \
	"Not adding locks/dev/codetracer/$MERGE_SHA.xml: codetracer@$MERGE_SHA is already recorded"
check "observed: ...with the manifests branch left where it was" "$(remote_tip)" "$BEFORE_TIP"
refresh_checkout
check "observed: ...and no legacy record filed beside the observation" \
	"$(test -e "$CHECKOUT/locks/dev/codetracer/$MERGE_SHA.xml" && echo yes || echo no)" "no"
resolve_as_recorder nim-agents "$MERGE_SHA"
check "observed: ...so the commit resolves to what was OBSERVED at it" "$RESOLVE_OUT" "$SIB_OBS"

# (c) a participation record is not a lock: the commit is still unlocked, and
#     the carry must still reach it.
plant_participation_target() {
	mkdir -p "$MAN_WORK/locks/team/codetracer"
	printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nrevision = "%s"\n' "$MERGE_SHA" \
		>"$MAN_WORK/locks/team/codetracer/$MERGE_SHA.toml"
}
mk_manifests plant_participation_target
run_step
check "observed: a target recorded only by a participation record is still carried" "$RC" "0"
contains "observed: ...and the lock is published" "$OUT" \
	"Published locks/codetracer/codetracer/$MERGE_SHA.toml"

# (c2) the participation test is the resolver's SEMANTIC one, not "has no
#      schema": a schema-less document that names ANOTHER repo is a lock that
#      failed to declare itself (the resolver refuses it loudly, exit 5), so the
#      commit counts as recorded and nothing is carried beside it.
plant_undeclared_lock_target() {
	mkdir -p "$MAN_WORK/locks/team/codetracer"
	printf '[[repo]]\nname = "codetracer"\nrevision = "%s"\n\n  [[repo]]\n  name = "nim-agents"\n  revision = "%s"\n' \
		"$MERGE_SHA" "$SIB_OBS" >"$MAN_WORK/locks/team/codetracer/$MERGE_SHA.toml"
}
mk_manifests plant_undeclared_lock_target
BEFORE_TIP="$(remote_tip)"
run_step
check "observed: a schema-less record naming another repo counts as recorded" "$RC" "0"
check "observed: ...so nothing is carried beside it" "$(remote_tip)" "$BEFORE_TIP"

# (d) a same-path disagreement is still refused, exactly as in contract 3.
plant_observed_same_path() { observed_body >"$MAN_WORK/locks/codetracer/codetracer/$MERGE_SHA.toml"; }
mk_manifests plant_observed_same_path
BEFORE_TIP="$(remote_tip)"
run_step
check "observed: a carried set that DISAGREES at the same path is still a hard failure" "$RC" "1"
contains "observed: ...named as immutability" "$OUT" "Published records are immutable and this one is not rewritten"
check "observed: ...and nothing is pushed" "$(remote_tip)" "$BEFORE_TIP"

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
	echo "publish-workspace-lock step: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "publish-workspace-lock step: all contracts hold."
