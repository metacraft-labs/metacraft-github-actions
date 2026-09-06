#!/usr/bin/env bash
#
# assert-action-archive-size-test.sh — contract suite for the archive-size guard.
#
# The point of this file is the NEGATIVE cases. A size check that has never
# rejected anything is decoration: it can pass forever with a broken extractor,
# a comparison that never fires, or a `curl` that silently returns nothing. So
# the suite asserts, against the real codeload endpoint:
#
#   1. the guard PASSES on this repository's actual `uses:` set;
#   2. it REJECTS the exact reference that caused the outage
#      (`metacraft-labs/reprobuild@dev`, 546 MB) at the real default budget;
#   3. it REJECTS a small archive when the budget is set below it, proving the
#      comparison fires rather than the fetch always coming back empty;
#   4. it ACCEPTS that same archive one byte above its size, proving the
#      boundary is where it claims to be and case 3 was not a fluke;
#   5. it treats an unmeasurable archive as a failure, not a pass;
#   6. it treats "extracted nothing" as a guard failure (exit 2), not a pass;
#   7. it ignores `uses:` that appear inside COMMENTS, because the rationale
#      block in setup-dev-env quotes the very reference this guard forbids;
#   8. it ignores local `./` references, which cost no download.
#
# Needs network: the sizes it asserts on are the real ones. Cost is bounded by
# the budget in force (the guard stops reading at BUDGET+1), so the 546 MB case
# transfers 32 MiB, not 546 MB.
#
# Run:  bash .github/assert-action-archive-size-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/assert-action-archive-size.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
	printf 'FAIL %s\n' "$1"
	shift
	[ "$#" -gt 0 ] && printf '     %s\n' "$@"
	failures=$((failures + 1))
}

# Build a throwaway repo root holding one synthetic action, so the guard's
# no-argument discovery (*/action.yml at depth 2) has something to find.
mkaction() { # <dir> <uses-line...>
	local d="$TMP/$1"
	shift
	mkdir -p "$d"
	{
		echo "name: synthetic"
		echo "description: fixture"
		echo "runs:"
		echo "  using: composite"
		echo "  steps:"
		local u
		for u in "$@"; do
			echo "    - uses: $u"
		done
	} >"$d/action.yml"
	printf '%s\n' "$d/action.yml"
}

# ---------------------------------------------------------------- case 1 ----
# The real repository must pass at the real budget. This is the regression
# assertion for the fix: with the two reprobuild actions relocated here, no
# `uses:` in this repo points at a large archive any more.
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "the repository's own \`uses:\` set is within budget"
else
	fail "the repository's own \`uses:\` set should be within budget (exit $rc)" "$out"
fi

# It must also have actually measured metacraft-github-actions itself — if the
# extractor silently found nothing, case 1 would have exited 2, but assert the
# positive too so a future refactor cannot quietly empty the set.
case "$out" in
*"assert-action-archive-size:"*"within budget"*) pass "the pass path reports a count" ;;
*) fail "the pass path did not report a measured count" "$out" ;;
esac

# ---------------------------------------------------------------- case 2 ----
# The historical offender, at the real default budget. This is the assertion
# that the guard would have caught the outage.
f="$(mkaction big "metacraft-labs/reprobuild/.github/actions/setup-reprobuild@dev")"
out="$(bash "$GUARD" "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
	pass "rejects metacraft-labs/reprobuild@dev at the default budget"
else
	fail "should reject metacraft-labs/reprobuild@dev at the default budget (exit $rc)" "$out"
fi
case "$out" in
*"FAIL metacraft-labs/reprobuild@dev"*) pass "names the offending repo@ref, not the sub-path" ;;
*) fail "did not name metacraft-labs/reprobuild@dev in the failure" "$out" ;;
esac
case "$out" in
*"100-second"*) pass "the failure explains the 100-second timeout" ;;
*) fail "the failure did not explain why size matters" "$out" ;;
esac

# ---------------------------------------------------------------- case 3 ----
# A small archive under a deliberately tiny budget must be REJECTED. If the
# fetch were silently returning nothing, or the comparison never firing, this
# is the case that catches it.
f="$(mkaction small "metacraft-labs/metacraft-github-actions@dev")"
out="$(ACTION_ARCHIVE_MAX_BYTES=1024 bash "$GUARD" "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
	pass "rejects a small archive when the budget is below its size"
else
	fail "should reject a 186 KB archive against a 1024-byte budget (exit $rc)" "$out"
fi

# ---------------------------------------------------------------- case 4 ----
# ... and accept it just above its own size. Together with case 3 this pins the
# boundary to the archive's real size rather than to some constant.
real="$(ACTION_ARCHIVE_MAX_BYTES=33554432 bash "$GUARD" "$f" 2>&1 |
	sed -n 's/.*): \([0-9][0-9]*\) bytes.*/\1/p' | head -1)"
if [ -z "$real" ]; then
	fail "could not read the measured size back out of the ok line"
else
	pass "reports a concrete measured size ($real bytes)"
	out="$(ACTION_ARCHIVE_MAX_BYTES="$real" bash "$GUARD" "$f" 2>&1)"
	if [ $? -eq 0 ]; then
		pass "accepts an archive exactly at the budget"
	else
		fail "should accept an archive exactly at the budget" "$out"
	fi
	out="$(ACTION_ARCHIVE_MAX_BYTES=$((real - 1)) bash "$GUARD" "$f" 2>&1)"
	if [ $? -eq 1 ]; then
		pass "rejects the same archive one byte below the budget"
	else
		fail "should reject an archive one byte over the budget" "$out"
	fi
fi

# ---------------------------------------------------------------- case 5 ----
# An archive that cannot be fetched must FAIL, not pass. "We could not measure
# it" is the state in which a 546 MB repo would sail through.
f="$(mkaction gone "metacraft-labs/metacraft-github-actions@ref-that-does-not-exist-9f3a1c")"
out="$(bash "$GUARD" "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
	pass "treats an unmeasurable archive as a failure"
else
	fail "an unfetchable ref must fail the guard, not pass it (exit $rc)" "$out"
fi

# ---------------------------------------------------------------- case 6 ----
# Extracting nothing is a guard failure (exit 2), distinct from a pass.
d="$TMP/empty/noop"
mkdir -p "$d"
printf 'name: x\ndescription: y\nruns:\n  using: composite\n  steps: []\n' >"$d/action.yml"
out="$(bash "$GUARD" "$d/action.yml" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
	pass "exits 2 when it extracted no targets at all"
else
	fail "measuring zero targets must exit 2, not $rc" "$out"
fi

# ---------------------------------------------------------------- case 7 ----
# A `uses:` inside a comment must not be measured. setup-dev-env's rationale
# block quotes `metacraft-labs/reprobuild/...@dev` verbatim; if the extractor
# picked that up, the guard would fail on its own explanation of itself.
d="$TMP/commented/act"
mkdir -p "$d"
cat >"$d/action.yml" <<'YAML'
name: x
description: y
runs:
  using: composite
  steps:
    # This used to be:
    #     uses: metacraft-labs/reprobuild/.github/actions/setup-reprobuild@dev
    # and that is why the guard exists.
    - uses: metacraft-labs/metacraft-github-actions@dev
YAML
out="$(bash "$GUARD" "$d/action.yml" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "ignores a \`uses:\` that appears inside a comment"
else
	fail "a commented-out \`uses:\` must not be measured (exit $rc)" "$out"
fi
case "$out" in
*reprobuild*) fail "the commented reference was measured anyway" "$out" ;;
*) pass "the commented reference does not appear in the report" ;;
esac

# ---------------------------------------------------------------- case 8 ----
# Local `./` references cost no download and must be skipped — but a file that
# contains ONLY those has no targets, which is case 6's exit 2.
d="$TMP/local/act"
mkdir -p "$d"
printf 'name: x\ndescription: y\nruns:\n  using: composite\n  steps:\n    - uses: ./sibling\n' >"$d/action.yml"
out="$(bash "$GUARD" "$d/action.yml" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
	pass "skips local ./ references (leaving nothing to measure -> exit 2)"
else
	fail "local ./ references must not be fetched (exit $rc)" "$out"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "assert-action-archive-size-test: all cases passed."
	exit 0
fi
echo "assert-action-archive-size-test: ${failures} case(s) failed."
exit 1
