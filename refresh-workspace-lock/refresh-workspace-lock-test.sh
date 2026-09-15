#!/usr/bin/env bash
#
# refresh-workspace-lock-test.sh — contract suite for refresh-workspace-lock.sh.
#
# WHAT IS BEING CONTRACTED
# ------------------------
# One property, and everything here is an instance of it:
#
#     THIS ACTION NEVER PRODUCES A LOCK. It runs the generator and carries what
#     the generator wrote, or it refuses and says why.
#
# That matters because the thing on the other end of this action is an
# IMMUTABLE published record. A lock asserting a composition that was never
# built is worse than no lock at all: a missing lock fails loudly at
# `clone-siblings` with a named remedy, while a fabricated one succeeds and
# mis-pins every consumer in silence. So the arms below are mostly REFUSALS, and
# the most important of them is the one where a perfectly well-formed lock is on
# disk and this run cannot show that it wrote it.
#
# THE ONE SHIM, AND WHY IT IS ONE
# -------------------------------
# `repro` is replaced by a real bash program on PATH, per scenario. It is not a
# mock object: it is a program that writes real files into a real workspace and
# exits with a real status, and the script under test cannot tell it from the
# CLI. The alternative is materialising a fifty-repo private workspace inside a
# contract suite, which would make this suite unrunnable and would test the
# reprobuild CLI rather than this action's decisions.
#
# What that shim cannot cover is stated rather than papered over: whether the
# real `repro ws lock` writes `[lock] created_at` in the shape this script
# reads. That is asserted directly against a REAL published lock record from the
# manifests repo, checked in beside this suite as testdata — so the format
# contract is pinned to an artifact nobody here wrote.
#
# Every scenario builds a fresh workspace on disk. Nothing is reused between
# arms, because the defect this action must never have is precisely "state left
# behind by an earlier run was published as if this run had made it".
#
# Run: bash refresh-workspace-lock/refresh-workspace-lock-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-workspace-lock.sh"
ACTION="$HERE/action.yml"

[ -f "$SCRIPT" ] || {
	echo "refresh-workspace-lock-test: cannot find $SCRIPT" >&2
	exit 2
}
bash -n "$SCRIPT" || {
	echo "refresh-workspace-lock-test: $SCRIPT is not valid bash (see above)." >&2
	exit 2
}

EXPECTED_ASSERTIONS=47
PASS=0
FAIL=0
ASSERTIONS=0

ok() {
	ASSERTIONS=$((ASSERTIONS + 1))
	PASS=$((PASS + 1))
	printf 'ok   %s\n' "$1"
}
bad() {
	ASSERTIONS=$((ASSERTIONS + 1))
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check() { # <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
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

NOW="$(date -u +%s)"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# A lock document in the shape reprobuild writes.
# ---------------------------------------------------------------------------
mk_lock() { # <path> <created_at> <codetracer-rev>
	cat >"$1" <<EOF
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "codetracer"
created_at = "$2"
created_by = "repro workspace lock"

[[repo]]
name = "codetracer"
path = "codetracer"
remote = "metacraft-labs"
revision = "$3"
branch = "dev"

[[repo]]
name = "codetracer-trace-format"
path = "codetracer-trace-format"
remote = "metacraft-labs"
revision = "4444444444444444444444444444444444444444"
branch = "dev"
EOF
}

OLD_REV="ac0cec4600000000000000000000000000000000"
NEW_REV="dd971ae300000000000000000000000000000000"

# ---------------------------------------------------------------------------
# mk_ws <name> <repro-behaviour> -> echoes the workspace root
#
# <repro-behaviour> is the body of the `repro` shim, so each scenario states
# exactly what the generator does.
# ---------------------------------------------------------------------------
mk_ws() { # <name> <shim-body>
	local body="$2" root="$TMPROOT/$1"
	mkdir -p "$root/.repro" "$root/codetracer-js-recorder/.git" "$root/bin"
	mk_lock "$root/codetracer-js-recorder/repro.lock" "2026-06-01T09:00:00Z" "$OLD_REV"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' "ROOT=\"$root\""
		printf '%s\n' "OLD_REV=\"$OLD_REV\""
		printf '%s\n' "NEW_REV=\"$NEW_REV\""
		printf '%s\n' "$body"
	} >"$root/bin/repro"
	chmod +x "$root/bin/repro"
	printf '%s' "$root"
}

# A shim that regenerates the lock with a fresh timestamp and a moved pin: the
# ordinary, successful case.
SHIM_REFRESH='
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$ROOT/codetracer-js-recorder/repro.lock" <<EOF
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "codetracer"
created_at = "$now"
created_by = "repro workspace lock"

[[repo]]
name = "codetracer"
path = "codetracer"
remote = "metacraft-labs"
revision = "$NEW_REV"
branch = "dev"

[[repo]]
name = "codetracer-trace-format"
path = "codetracer-trace-format"
remote = "metacraft-labs"
revision = "4444444444444444444444444444444444444444"
branch = "dev"
EOF
exit 0
'

run_script() { # <workspace-root> [env assignments...]
	local root="$1"
	shift
	SUMMARY="$TMPROOT/summary.md"
	OUTPUTS="$TMPROOT/outputs.txt"
	: >"$SUMMARY"
	: >"$OUTPUTS"
	OUT="$(
		env PATH="$root/bin:$PATH" \
			WORKSPACE_ROOT="$root" \
			REPO_NAME="codetracer-js-recorder" \
			DRY_RUN="true" \
			SUMMARY_FILE="$SUMMARY" \
			OUTPUT_FILE="$OUTPUTS" \
			NOW_EPOCH="$NOW" \
			"$@" \
			bash "$SCRIPT" 2>&1
	)"
	RC=$?
	SUMMARY_TEXT="$(cat "$SUMMARY")"
	OUTPUT_TEXT="$(cat "$OUTPUTS")"
}

# ===========================================================================
# 1. The ordinary case: a real difference, reported, with nothing touched.
# ===========================================================================
WS="$(mk_ws happy "$SHIM_REFRESH")"
BEFORE="$(sha_of "$WS/codetracer-js-recorder/repro.lock")"
run_script "$WS"
check "dry run over a moved pin succeeds" "$RC" "0"
contains "...and names the pin that moved" "$OUT" "codetracer\`: $OLD_REV -> $NEW_REV"
contains "...and reports status=would-refresh" "$OUTPUT_TEXT" "status=would-refresh"
contains "...and reports changed=true" "$OUTPUT_TEXT" "changed=true"
contains "...and the step summary states the composition change" "$SUMMARY_TEXT" "Pins that moved"
contains "...and says no pull request was opened" "$SUMMARY_TEXT" "no pull request was opened"
check "...and the checkout is restored byte-for-byte" \
	"$(sha_of "$WS/codetracer-js-recorder/repro.lock")" "$BEFORE"
lacks "...and no branch was created" "$OUT" "opening a pull request"

# ===========================================================================
# 2. Nothing to refresh: the generator writes the same bytes back.
#
# This is the common case on a schedule, and it must be cheap and silent-ish:
# exit 0, changed=false, no proposal.
# ===========================================================================
SHIM_SAME='exit 0'
WS="$(mk_ws same "$SHIM_SAME")"
BEFORE="$(sha_of "$WS/codetracer-js-recorder/repro.lock")"
run_script "$WS"
check "an unchanged lock is a success" "$RC" "0"
contains "...reported as unchanged" "$OUTPUT_TEXT" "status=unchanged"
contains "...and changed=false" "$OUTPUT_TEXT" "changed=false"
check "...with the file untouched" \
	"$(sha_of "$WS/codetracer-js-recorder/repro.lock")" "$BEFORE"

# ===========================================================================
# 3. THE ANTI-FABRICATION GUARD.
#
# A DIFFERENT, perfectly well-formed lock is on disk and its `created_at`
# predates this run: the generator did not write it, so this run must not
# propose it. Without this arm a dirty checkout — an interrupted earlier run, a
# restored cache, somebody's branch — becomes a published record under this
# action's name.
# ===========================================================================
SHIM_PRE_EXISTING='
cat >"$ROOT/codetracer-js-recorder/repro.lock" <<EOF
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "codetracer"
created_at = "2020-01-01T00:00:00Z"
created_by = "repro workspace lock"

[[repo]]
name = "codetracer"
revision = "$NEW_REV"
EOF
exit 0
'
WS="$(mk_ws stale-provenance "$SHIM_PRE_EXISTING")"
run_script "$WS"
check "a changed lock created before this run is refused" "$RC" "5"
contains "...saying it was not generated by this run" "$OUT" "this run did not generate it"
contains "...and reports status=refused" "$OUTPUT_TEXT" "status=refused"
lacks "...and does not claim a refresh" "$OUTPUT_TEXT" "status=would-refresh"

# 3b. A changed lock with NO created_at at all. Same refusal: provenance that
#     cannot be read is provenance that cannot be trusted.
SHIM_NO_PROVENANCE='
cat >"$ROOT/codetracer-js-recorder/repro.lock" <<EOF
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "codetracer"

[[repo]]
name = "codetracer"
revision = "$NEW_REV"
EOF
exit 0
'
WS="$(mk_ws no-provenance "$SHIM_NO_PROVENANCE")"
run_script "$WS"
check "a changed lock with no created_at is refused" "$RC" "5"
contains "...saying the provenance cannot be shown" "$OUT" "carries no '[lock] created_at'"

# 3c. A `created_at` under `[[repo]]` is not the lock's. Reading it as the
#     lock's would let a record carrying any repo-level date pass the guard.
SHIM_REPO_LEVEL_DATE='
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$ROOT/codetracer-js-recorder/repro.lock" <<EOF
schema = "reprobuild.workspace.lock.v1"

[lock]
project = "codetracer"

[[repo]]
name = "codetracer"
created_at = "$now"
revision = "$NEW_REV"
EOF
exit 0
'
WS="$(mk_ws repo-level-date "$SHIM_REPO_LEVEL_DATE")"
run_script "$WS"
check "a [[repo]] created_at does not satisfy the guard" "$RC" "5"
contains "...and says so as a provenance failure" "$OUT" "carries no '[lock] created_at'"

# ===========================================================================
# 4. The generator failing is exit 4, and nothing is touched.
# ===========================================================================
SHIM_FAIL='echo "repro: the workspace is inconsistent" >&2; exit 7'
WS="$(mk_ws genfail "$SHIM_FAIL")"
BEFORE="$(sha_of "$WS/codetracer-js-recorder/repro.lock")"
run_script "$WS"
check "a failing generator is exit 4" "$RC" "4"
contains "...naming the exit status it got" "$OUT" "exited 7"
contains "...and its output is shown, not swallowed" "$OUT" "the workspace is inconsistent"
check "...and the lock is untouched" \
	"$(sha_of "$WS/codetracer-js-recorder/repro.lock")" "$BEFORE"

# 4b. The generator succeeding and deleting the lock is exit 5, not a rewrite.
SHIM_DELETES='rm -f "$ROOT/codetracer-js-recorder/repro.lock"; exit 0'
WS="$(mk_ws deletes "$SHIM_DELETES")"
run_script "$WS"
check "a generator that reports success and leaves no lock is exit 5" "$RC" "5"
contains "...refusing to invent one" "$OUT" "Refusing to invent one"

# ===========================================================================
# 5. Environment refusals. Each is a case where another implementation would be
#    tempted to do its best, and doing its best means fabricating.
# ===========================================================================
WS="$(mk_ws nocli "$SHIM_REFRESH")"
rm -f "$WS/bin/repro"
run_script "$WS" REPRO="definitely-not-a-real-cli-name"
check "no reprobuild CLI is exit 3" "$RC" "3"
contains "...saying hand-deriving is the failure mode being avoided" "$OUT" "hand-deriving one is the failure mode"

WS="$(mk_ws notws "$SHIM_REFRESH")"
rm -rf "$WS/.repro"
run_script "$WS"
check "a directory that is not a workspace is exit 3" "$RC" "3"
contains "...naming the remedy" "$OUT" "repro workspace init"

WS="$(mk_ws norepo "$SHIM_REFRESH")"
rm -rf "$WS/codetracer-js-recorder/.git"
run_script "$WS"
check "a missing checkout of the repo is exit 3" "$RC" "3"
contains "...saying the lock is keyed by a commit of it" "$OUT" "keyed by a commit"

# ===========================================================================
# 6. DRY_RUN is a permission, and a typo is not permission.
# ===========================================================================
WS="$(mk_ws badflag "$SHIM_REFRESH")"
BEFORE="$(sha_of "$WS/codetracer-js-recorder/repro.lock")"
run_script "$WS" DRY_RUN="yes"
check "an unrecognised dry-run value is exit 2" "$RC" "2"
contains "...and says a typo is not permission" "$OUT" "must not be read as permission"
check "...and nothing was generated" \
	"$(sha_of "$WS/codetracer-js-recorder/repro.lock")" "$BEFORE"

# ===========================================================================
# 7. THE ACTION STILL RUNS THIS SCRIPT, and still defaults to a dry run.
#
# Without these two, the suite could stay green while the action invoked
# something else, or while `dry-run` had silently become `false` by default —
# which would turn a scheduled reporting job into a scheduled pushing one.
# ===========================================================================
ACTION_TEXT="$(cat "$ACTION")"
contains "the action runs the script this suite tests" "$ACTION_TEXT" \
	'run: bash "${GITHUB_ACTION_PATH}/refresh-workspace-lock.sh"'
contains "the action's dry-run input still defaults to true" "$ACTION_TEXT" \
	'dry-run:'
DRYDEF="$(awk '/^  dry-run:/{f=1} f && /^    default:/{print $2; exit}' "$ACTION")"
check "...and that default is \"true\"" "$DRYDEF" '"true"'
for v in WORKSPACE_ROOT REPO_NAME REPRO DRY_RUN BRANCH_PREFIX; do
	contains "the action passes $v in the step's env:" "$ACTION_TEXT" "        ${v}: "
done

# ===========================================================================
# 8. THE FORMAT CONTRACT, against a record nobody in this repository wrote.
#
# Every arm above uses a shim, so every arm above would stay green if the real
# `repro ws lock` wrote its provenance under some other key or in some other
# table. This arm reads a REAL published lock record — checked in under
# testdata/ from the manifests repo — and asserts the script's own extractor
# gets the value out of it. If reprobuild changes the field, this fails here
# rather than in production, where the symptom would be a refusal to refresh
# anything, forever, quietly.
# ===========================================================================
# metacraft-labs/metacraft-manifests@latest,
# locks/codetracer/codetracer-launcher/3afaaa47539cda40eb2935a8be967458e94c9a1a.toml,
# copied byte-for-byte. The digest is pinned so a "helpful" edit to the fixture
# -- a reformat, a trimmed tail, a hand-adjusted date -- turns it back into
# something this repository wrote, which is exactly what it must not be.
REAL_LOCK="$HERE/testdata/real-published-lock.toml"
REAL_LOCK_SHA256="745e7fb54d06d88de96a343eb98c347892ac3bcfc72eb98f778726f455e261ac"
if [ -f "$REAL_LOCK" ]; then
	ok "a real published lock record is checked in as testdata"
	check "...and it is still the published bytes (sha256)" \
		"$(sha_of "$REAL_LOCK")" "$REAL_LOCK_SHA256"
	EXTRACTED="$(
		awk '
			/^[[:space:]]*\[/ { in_lock = ($0 ~ /^[[:space:]]*\[lock\][[:space:]]*$/); next }
			in_lock && /^[[:space:]]*created_at[[:space:]]*=/ {
				line = $0
				sub(/^[^=]*=[[:space:]]*/, "", line)
				gsub(/^["'"'"']|["'"'"']$/, "", line)
				print line
				exit
			}
		' "$REAL_LOCK"
	)"
	case "$EXTRACTED" in
	20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) ok "...and its [lock] created_at reads as an ISO-8601 instant ($EXTRACTED)" ;;
	*) bad "...and its [lock] created_at reads as an ISO-8601 instant" "got [$EXTRACTED]" ;;
	esac
	if date -u -d "$EXTRACTED" +%s >/dev/null 2>&1 ||
		date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXTRACTED" +%s >/dev/null 2>&1; then
		ok "...and the guard's own date parsing accepts it"
	else
		bad "...and the guard's own date parsing accepts it" "neither date flavour parsed [$EXTRACTED]"
	fi
else
	bad "a real published lock record is checked in as testdata" \
		"missing $REAL_LOCK; the format contract would be asserted only against this suite's own fixtures"
fi

# ===========================================================================

printf '\n%s\n' "assertions: $ASSERTIONS  pass: $PASS  fail: $FAIL"
if [ "$ASSERTIONS" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf '%s\n' "refresh-workspace-lock-test: expected $EXPECTED_ASSERTIONS assertions, ran $ASSERTIONS." >&2
	printf '%s\n' "  A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
[ "$FAIL" -eq 0 ] || exit 1
printf '%s\n' "refresh-workspace-lock: all contracts hold."
