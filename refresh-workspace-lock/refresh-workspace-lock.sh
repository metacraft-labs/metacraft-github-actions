#!/usr/bin/env bash
#
# refresh-workspace-lock.sh — the body of the `refresh-workspace-lock` action.
#
# WHAT PROBLEM THIS SOLVES, AND WHY IT IS THE ONLY SHAPE THAT SOLVES IT
# ---------------------------------------------------------------------
# A workspace lock record is keyed by a COMMIT of the repo it describes, and it
# is published by that repo's local pre-push gate, which GENERATES it from a
# workspace that actually existed. `publish-workspace-lock` then CARRIES that
# record forward: every sibling pin copied verbatim, precisely one field changed
# (the entry naming the repo itself). The carry is right and must not refresh —
# a refreshed pin would be a statement of fact about a workspace nobody ever had,
# and a fabricated lock succeeds silently where a missing one fails loudly.
#
# The consequence is that a sibling pin can only move when some NEW commit of
# this repo gets a lock GENERATED (not carried) in a workspace where that
# sibling is newer. Absent such a commit, the pin a recorder repo was locked at
# months ago is re-anchored onto every future push, forever, and a fix landed in
# a sibling never reaches this repo's cross-repo CI.
#
# So the missing operation is REFRESH, and it has exactly one honest form: make
# a real workspace, let the real tool generate a real lock from it, and put the
# result up as a PULL REQUEST — so the refreshed composition is BUILT by that
# PR's own CI before anything is published, and the existing carry propagates it
# from the merge onward. That is the whole design. Everything below is in
# service of one rule:
#
#     THIS SCRIPT NEVER PRODUCES A LOCK. It runs the generator and carries what
#     the generator wrote, or it refuses and says why.
#
# There is no code path here that writes, edits, patches or synthesises a lock
# document, and the contract suite asserts that a lock this run did not generate
# is refused rather than published.
#
# ENVIRONMENT
#   WORKSPACE_ROOT   (required) the reprobuild workspace root — the directory
#                    holding `.repro/`, with the participating repos beside it.
#   REPO_NAME        (required) the repo whose lock is being refreshed; a
#                    directory of that name must exist under WORKSPACE_ROOT.
#   REPRO            (optional) the reprobuild CLI to invoke. Default `repro`.
#   DRY_RUN          (optional) `true` (default) reports and changes nothing.
#   BRANCH_PREFIX    (optional) branch name prefix for the PR. Default
#                    `chore/refresh-workspace-lock`.
#   SUMMARY_FILE     (optional) where to write the human summary. Default
#                    $GITHUB_STEP_SUMMARY when set, else /dev/null.
#   OUTPUT_FILE      (optional) where to write `key=value` outputs. Default
#                    $GITHUB_OUTPUT when set, else /dev/null.
#   NOW_EPOCH        (optional, testing) override for "when this run started".
#
# EXIT CODES
#   0  done: either nothing to refresh, or a refresh was prepared/opened
#   2  usage — a required input is missing or contradictory
#   3  the environment cannot produce a lock (no CLI, not a workspace, ...)
#   4  the generator ran and FAILED
#   5  the generator reported success but what is on disk cannot be trusted
#      (unchanged when it should have changed, or a lock this run did not
#      generate). Deliberately distinct from 4: 4 is "the tool said no", 5 is
#      "the tool said yes and the evidence disagrees", and only 5 means somebody
#      has to look at the workspace.
#
# Contract suite: ./refresh-workspace-lock-test.sh
set -uo pipefail

ME="refresh-workspace-lock"

WORKSPACE_ROOT="${WORKSPACE_ROOT-}"
REPO_NAME="${REPO_NAME-}"
REPRO="${REPRO:-repro}"
DRY_RUN="${DRY_RUN:-true}"
BRANCH_PREFIX="${BRANCH_PREFIX:-chore/refresh-workspace-lock}"
SUMMARY_FILE="${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/null}}"
OUTPUT_FILE="${OUTPUT_FILE:-${GITHUB_OUTPUT:-/dev/null}}"
NOW_EPOCH="${NOW_EPOCH:-$(date -u +%s)}"

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >>"$SUMMARY_FILE"; }
out() { printf '%s\n' "$1" >>"$OUTPUT_FILE"; }

die() { # <code> <message...>
	local rc="$1"
	shift
	printf '%s: %s\n' "$ME" "$*" >&2
	out "status=refused"
	exit "$rc"
}

[ -n "$WORKSPACE_ROOT" ] || die 2 "WORKSPACE_ROOT is empty. There is no workspace to generate a lock from, and this action will not derive one from anything else."
[ -n "$REPO_NAME" ] || die 2 "REPO_NAME is empty."

case "$DRY_RUN" in
true | false) ;;
*) die 2 "DRY_RUN must be 'true' or 'false'; got '$DRY_RUN'. A typo must not be read as permission to open a pull request." ;;
esac

# ---------------------------------------------------------------------------
# Preconditions. Each is a REFUSAL, not a fallback.
#
# Every one of these is a condition under which some other implementation could
# be tempted to "do its best" — write the lock itself, copy a neighbouring one,
# take the branch tip. Each of those produces a document asserting that a
# combination builds without anything having built it, which this project's own
# rule puts below having no lock at all. So each is an exit, with the remedy.
# ---------------------------------------------------------------------------
[ -d "$WORKSPACE_ROOT" ] || die 3 "WORKSPACE_ROOT '$WORKSPACE_ROOT' does not exist."
[ -d "$WORKSPACE_ROOT/.repro" ] || die 3 "'$WORKSPACE_ROOT' has no .repro/ directory, so it is not a reprobuild workspace. A lock generated anywhere else would describe a workspace that does not exist. Materialise the workspace first ('repro workspace init <org>')."

REPO_DIR="$WORKSPACE_ROOT/$REPO_NAME"
[ -d "$REPO_DIR/.git" ] || die 3 "'$REPO_DIR' is not a git checkout. The lock is keyed by a commit of $REPO_NAME, so the repo has to be present at a commit."

command -v "$REPRO" >/dev/null 2>&1 || die 3 "'$REPRO' is not on PATH. The lock must be generated by the reprobuild CLI from the real workspace; hand-deriving one is the failure mode this action exists to avoid."

LOCK="$REPO_DIR/repro.lock"

hash_of() { # <path> -> sha256 or the empty string when absent
	[ -f "$1" ] || return 0
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		return 1
	fi
}

BEFORE_HASH="$(hash_of "$LOCK")" || die 3 "no sha256 tool (sha256sum/shasum) is available, so this run cannot tell a lock it generated from one that was already there. That distinction is the whole safety property here."
BEFORE_COPY=""
if [ -f "$LOCK" ]; then
	BEFORE_COPY="$(mktemp)"
	cp "$LOCK" "$BEFORE_COPY"
fi
cleanup() { [ -n "$BEFORE_COPY" ] && rm -f "$BEFORE_COPY"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Generate. The one command that is allowed to write the lock.
# ---------------------------------------------------------------------------
say "$ME: regenerating $REPO_NAME's lock from the workspace at $WORKSPACE_ROOT"
GEN_LOG="$(mktemp)"
GEN_RC=0
(cd "$REPO_DIR" && "$REPRO" ws lock) >"$GEN_LOG" 2>&1 || GEN_RC=$?
sed 's/^/  | /' "$GEN_LOG"
if [ "$GEN_RC" -ne 0 ]; then
	rm -f "$GEN_LOG"
	die 4 "'$REPRO ws lock' exited $GEN_RC. Nothing was published. The workspace is what has to be fixed; this action has no second way to produce a lock."
fi
rm -f "$GEN_LOG"

AFTER_HASH="$(hash_of "$LOCK")"

if [ ! -f "$LOCK" ]; then
	die 5 "'$REPRO ws lock' reported success and $LOCK does not exist. Refusing to invent one."
fi

if [ "$AFTER_HASH" = "$BEFORE_HASH" ]; then
	say "$ME: the lock is unchanged — the workspace composition already matches what $REPO_NAME records."
	note "**refresh-workspace-lock**: \`$REPO_NAME\` — nothing to refresh. The generated lock is byte-identical to the committed one (sha256 \`$AFTER_HASH\`)."
	out "status=unchanged"
	out "changed=false"
	exit 0
fi

# ---------------------------------------------------------------------------
# THE ANTI-FABRICATION GUARD, and the reason this action can be trusted with a
# `git push`.
#
# A changed file is not evidence that THIS RUN generated it. A workspace can
# arrive with a dirty `repro.lock` from anything at all — an interrupted earlier
# run, a restored cache, a checkout of somebody's branch — and publishing that
# would put a document nobody generated into the immutable record, under this
# action's name. So the post-state has to say, in its own body, that it was
# written after this run started.
#
# `[lock] created_at` is the field reprobuild writes for exactly this purpose,
# and it is the same field `clone-siblings` now reports at consumption. If it is
# absent, or older than this run, the refresh is refused. A false NEGATIVE here
# costs a skipped refresh and a loud message; a false positive costs a
# fabricated pin in an immutable record, which is the thing that must not happen.
# ---------------------------------------------------------------------------
lock_created_at() { # <lock> -> the [lock] created_at value, or empty
	awk '
		/^[[:space:]]*\[/ { in_lock = ($0 ~ /^[[:space:]]*\[lock\][[:space:]]*$/); next }
		in_lock && /^[[:space:]]*created_at[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*/, "", line)
			gsub(/^["'"'"']|["'"'"']$/, "", line)
			print line
			exit
		}
	' "$1"
}

to_epoch() { # <iso-8601> -> epoch seconds, or nothing
	local ts="$1" s=""
	s=$(date -u -d "$ts" +%s 2>/dev/null) || s=""
	[ -n "$s" ] || s=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) || s=""
	[ -n "$s" ] && printf '%s' "$s"
}

CREATED_AT="$(lock_created_at "$LOCK")"
[ -n "$CREATED_AT" ] || die 5 "the regenerated $LOCK carries no '[lock] created_at', so this run cannot show that it generated it rather than finding it. Refusing to open a pull request for a lock of unknown provenance."

CREATED_EPOCH="$(to_epoch "$CREATED_AT")"
[ -n "$CREATED_EPOCH" ] || die 5 "cannot read '$CREATED_AT' as a timestamp, so the lock's provenance cannot be established. Refusing."

# One minute of slack for a runner clock that is not exactly the lock writer's.
if [ "$CREATED_EPOCH" -lt "$((NOW_EPOCH - 60))" ]; then
	die 5 "the regenerated $LOCK says it was created at $CREATED_AT, which is BEFORE this run started. It was already in the tree; this run did not generate it. Refusing to publish a lock whose provenance is not this workspace."
fi

# ---------------------------------------------------------------------------
# What moved. The pull request has to state the composition change, because the
# whole point of the pull request is that a human and a CI run get to see it.
# ---------------------------------------------------------------------------
pins_of() { # <lock> -> "<name> <revision>" per line
	awk '
		/^[[:space:]]*\[\[repo\]\][[:space:]]*$/ { if (name != "") print name, rev; name=""; rev=""; next }
		/^[[:space:]]*\[/ { if (name != "") print name, rev; name=""; rev=""; next }
		/^[[:space:]]*name[[:space:]]*=/  { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/^["'"'"']|["'"'"']$/,"",v); name=v; next }
		/^[[:space:]]*revision[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/^["'"'"']|["'"'"']$/,"",v); rev=v; next }
		END { if (name != "") print name, rev }
	' "$1" | sort
}

MOVED=""
if [ -n "$BEFORE_COPY" ]; then
	OLD_PINS="$(pins_of "$BEFORE_COPY")"
	NEW_PINS="$(pins_of "$LOCK")"
	while IFS=' ' read -r n r; do
		[ -n "$n" ] || continue
		o="$(printf '%s\n' "$OLD_PINS" | awk -v k="$n" '$1==k {print $2; exit}')"
		if [ "$o" != "$r" ]; then
			MOVED="${MOVED}- \`${n}\`: ${o:-<not pinned>} -> ${r}
"
		fi
	done <<EOF
$NEW_PINS
EOF
fi
[ -n "$MOVED" ] || MOVED="- (no \`[[repo]]\` pin moved; the lock differs in its header only)
"

say "$ME: the refreshed composition differs:"
printf '%s' "$MOVED" | sed 's/^/  /'

BRANCH="${BRANCH_PREFIX}/$(date -u -d "@$NOW_EPOCH" +%Y%m%d 2>/dev/null || date -u +%Y%m%d)"
out "changed=true"
out "branch=$BRANCH"
out "created_at=$CREATED_AT"

{
	printf '%s\n' "### refresh-workspace-lock: \`$REPO_NAME\`"
	printf '%s\n' ""
	printf '%s\n' "A workspace was materialised and \`$REPRO ws lock\` regenerated \`repro.lock\` from it."
	printf '%s\n' "The generated record says it was created at \`$CREATED_AT\`."
	printf '%s\n' ""
	printf '%s\n' "Pins that moved:"
	printf '%s' "$MOVED"
	printf '%s\n' ""
} >>"$SUMMARY_FILE"

if [ "$DRY_RUN" = "true" ]; then
	# The tree is put back exactly as it was found. A dry run that left a
	# modified lock behind would be a wet run with extra steps, and the next
	# thing to read this checkout would find a lock nothing had reviewed.
	if [ -n "$BEFORE_COPY" ]; then
		cp "$BEFORE_COPY" "$LOCK"
	else
		rm -f "$LOCK"
	fi
	RESTORED_HASH="$(hash_of "$LOCK")"
	if [ "$RESTORED_HASH" != "$BEFORE_HASH" ]; then
		die 5 "dry run could not restore $LOCK to the bytes it found (sha256 $BEFORE_HASH -> ${RESTORED_HASH:-<absent>})."
	fi
	say "$ME: DRY RUN — no branch, no commit, no pull request. The lock was restored to the bytes this run found."
	note "_Dry run: no pull request was opened, and the checkout was restored._"
	out "status=would-refresh"
	exit 0
fi

# ---------------------------------------------------------------------------
# The pull request. Nothing here decides anything: the lock is already on disk,
# generated by the CLI and proven to be this run's.
# ---------------------------------------------------------------------------
say "$ME: opening a pull request on branch $BRANCH"
(
	cd "$REPO_DIR" || exit 1
	git switch -c "$BRANCH" || exit 1
	git add -- repro.lock || exit 1
	git -c user.name="metacraft-ci" -c user.email="ci@metacraft-labs.com" \
		commit -m "chore: refresh the workspace lock

Regenerated by 'refresh-workspace-lock' from a materialised workspace;
'$REPRO ws lock' wrote the record and this change carries it unmodified.
The composition below is UNVERIFIED until this pull request's own CI has
built it, which is why it arrives as a pull request and not as a push.

Pins that moved:
$MOVED" || exit 1
	git push origin "HEAD:$BRANCH" || exit 1
) || die 4 "could not prepare or push the refresh branch. Nothing was published."

out "status=refreshed"
say "$ME: pushed $BRANCH. Open a pull request from it; its CI builds the refreshed composition before anything is published."
