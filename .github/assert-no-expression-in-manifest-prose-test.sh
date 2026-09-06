#!/usr/bin/env bash
#
# assert-no-expression-in-manifest-prose-test.sh — contract suite for the
# manifest-prose guard.
#
# The point of this file is the NEGATIVE cases. The guard exists because a
# `${{ ... }}` in a `description:` shipped to 64 repos and failed every
# consumer's `Set up job`; a guard that cannot reproduce that is decoration.
# So the suite asserts:
#
#   1. this repository's own manifests pass;
#   2. the EXACT regression is rejected — `github.action_path` written in the
#      expression form inside a top-level `description:` block scalar, which
#      is the shape that actually shipped;
#   3. it is rejected on a single-line `description:` too;
#   4. it is rejected inside an input's `description:`;
#   5. expressions under `runs:` are ACCEPTED — that is where they belong, and
#      a guard that rejected them would be unusable;
#   6. `inputs.*.default` and `outputs.*.value` expressions are accepted, so
#      the guard has no false positives on legitimate manifests;
#   7. the guard fails loudly (exit 2) rather than passing when handed nothing;
#   8. the reported line number points at the offending line.
#
# Needs no network.
#
# Run:  bash .github/assert-no-expression-in-manifest-prose-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/assert-no-expression-in-manifest-prose.sh"
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

write() { # <name> <<heredoc
	local d="$TMP/$1"
	mkdir -p "$d"
	cat >"$d/action.yml"
	printf '%s\n' "$d/action.yml"
}

# ---------------------------------------------------------------- case 1 ----
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "this repository's manifests are clean"
else
	fail "this repository's manifests should be clean (exit $rc)" "$out"
fi
case "$out" in
*"manifest(s) clean"*) pass "the pass path reports a count" ;;
*) fail "the pass path did not report a count" "$out" ;;
esac

# ---------------------------------------------------------------- case 2 ----
# The exact regression: a block-scalar description explaining `action_path` in
# the expression form.
f="$(write blockdesc <<'YAML'
name: x
description: >
  This action does not read the far worktree: `install-release.sh` comes
  along via `${{ github.action_path }}`, and the fallback clones at runtime.

runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi
YAML
)"
out="$(bash "$GUARD" "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
	pass "rejects an expression in a block-scalar top-level description"
else
	fail "must reject the shape that actually shipped (exit $rc)" "$out"
fi
case "$out" in
*"no \`github\`"*) pass "the failure explains why the field is not a comment" ;;
*) fail "the failure did not explain the cause" "$out" ;;
esac
# case 8: it names the offending line, not just the file.
case "$out" in
*"action.yml:4:"*) pass "reports the offending line number" ;;
*) fail "did not report the offending line number" "$out" ;;
esac

# ---------------------------------------------------------------- case 3 ----
f="$(write inlinedesc <<'YAML'
name: x
description: uses ${{ github.action_path }} to find its helper
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi
YAML
)"
out="$(bash "$GUARD" "$f" 2>&1)"
if [ $? -eq 1 ]; then
	pass "rejects an expression in a single-line description"
else
	fail "a single-line description must be checked too" "$out"
fi

# ---------------------------------------------------------------- case 4 ----
f="$(write inputdesc <<'YAML'
name: x
description: fine
inputs:
  token:
    description: defaults to ${{ github.token }} when empty
    required: false
    default: ""
runs:
  using: composite
  steps:
    - shell: bash
      run: echo hi
YAML
)"
out="$(bash "$GUARD" "$f" 2>&1)"
if [ $? -eq 1 ]; then
	pass "rejects an expression in an input's description"
else
	fail "an input description must be checked too" "$out"
fi

# ---------------------------------------------------------------- case 5 ----
# The guard must NOT reject expressions where they are legal, or it is
# unusable and will be switched off.
f="$(write runsok <<'YAML'
name: x
description: plain prose naming github.action_path with no braces
runs:
  using: composite
  steps:
    - shell: bash
      run: bash "${{ github.action_path }}/install-release.sh"
    - uses: metacraft-labs/metacraft-github-actions/setup-nix@dev
      with:
        gh-token: ${{ inputs.gh-token }}
YAML
)"
out="$(bash "$GUARD" "$f" 2>&1)"
if [ $? -eq 0 ]; then
	pass "accepts expressions under runs:, where they belong"
else
	fail "expressions under runs: must be accepted" "$out"
fi

# ---------------------------------------------------------------- case 6 ----
f="$(write defaultsok <<'YAML'
name: x
description: plain prose
inputs:
  ref:
    description: the ref to use
    required: false
    default: ${{ github.sha }}
outputs:
  result:
    description: what happened
    value: ${{ steps.s.outputs.v }}
runs:
  using: composite
  steps:
    - id: s
      shell: bash
      run: echo "v=1" >> "$GITHUB_OUTPUT"
YAML
)"
out="$(bash "$GUARD" "$f" 2>&1)"
if [ $? -eq 0 ]; then
	pass "accepts inputs.*.default and outputs.*.value expressions"
else
	fail "legitimate default/value expressions must not be flagged" "$out"
fi

# ---------------------------------------------------------------- case 7 ----
out="$(bash "$GUARD" "$TMP/does-not-exist/action.yml" 2>&1)"
if [ $? -eq 2 ]; then
	pass "exits 2 on a missing file rather than passing"
else
	fail "a missing file must exit 2" "$out"
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "assert-no-expression-in-manifest-prose-test: all cases passed."
	exit 0
fi
echo "assert-no-expression-in-manifest-prose-test: ${failures} case(s) failed."
exit 1
