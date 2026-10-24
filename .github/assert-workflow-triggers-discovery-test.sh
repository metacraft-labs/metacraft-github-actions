#!/usr/bin/env bash
# Exercise discovery through the shipped guard and real workflow files. chmod
# removes directory access, and the real Node enumerator verifies the failure.
# The only test double is a runtime wrapper for partial enumeration: it runs
# the real Node enumerator, emits one of its real filenames, then fails. A read
# that fails after yielding a subset depends on filesystem races and ordering;
# this injection makes its exit-status contract deterministic. It does not
# replace the unmodified discovery, filter rejection or permission controls.
# Run as an unprivileged user; a filesystem that ignores the permission fixture
# is a test setup failure, never a skipped or passing case. This local test does
# not identify the cause of a failure on a different host.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/assert-workflow-triggers-mainline.sh"
ENUMERATOR="$HERE/enumerate-workflows.cjs"
WORKFLOW_DISCOVERY_TEST_REAL_NODE="$(command -v node)"
export WORKFLOW_DISCOVERY_TEST_REAL_NODE
export WORKFLOW_TRIGGERS_NODE="$WORKFLOW_DISCOVERY_TEST_REAL_NODE"
discovery_test_dir="$(mktemp -d)"
locked="$discovery_test_dir/unreadable/.github/workflows"
cleanup() {
  chmod u+rwx "$locked" 2>/dev/null || :
  rm -rf "$discovery_test_dir"
}
trap cleanup EXIT
export LC_ALL=C

mkdir -p "$discovery_test_dir/valid/.github/workflows" \
  "$discovery_test_dir/invalid/.github/workflows" \
  "$discovery_test_dir/empty/.github/workflows" "$locked"
cat >"$discovery_test_dir/valid/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [dev]
  pull_request:
    branches: [dev]
YAML
cat >"$discovery_test_dir/valid/.github/workflows/release.yaml" <<'YAML'
name: Release
on:
  push:
    tags: ['v*']
YAML
cat >"$discovery_test_dir/invalid/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [stable]
YAML
cp "$discovery_test_dir/valid/.github/workflows/ci.yml" "$locked/ci.yml"

failures=0
check() {
  local label="$1" expected="$2" root="$3" pattern output result matched=1
  shift 3
  if output="$(WORKFLOW_TRIGGERS_ROOT="$root" bash "$GUARD" dev 2>&1)"; then
    result=0
  else
    result=$?
  fi
  for pattern in "$@"; do
    [[ "$output" == *"$pattern"* ]] || matched=0
  done
  if [ "$result" -eq "$expected" ] && [ "$matched" -eq 1 ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: expected exit %s and [%s]; got exit %s\n%s\n' \
      "$label" "$expected" "$*" "$result" "$output"
    failures=$((failures + 1))
  fi
}

check 'discovers and checks both workflow suffixes' 0 "$discovery_test_dir/valid" '2 workflow(s)'
check 'discovery still rejects an incorrect branch filter' 1 "$discovery_test_dir/invalid" \
  'does not name the mainline'
check 'an actually empty workflow directory is refused' 2 "$discovery_test_dir/empty" \
  'no workflow files found'

# Positive control: the file is discoverable before changing permissions.
check 'the permission fixture initially contains a valid workflow' 0 \
  "$discovery_test_dir/unreadable" '1 workflow(s)'
chmod 000 "$locked"
if "$WORKFLOW_DISCOVERY_TEST_REAL_NODE" "$ENUMERATOR" "$locked" \
  >"$discovery_test_dir/discovery.stdout" 2>"$discovery_test_dir/discovery.stderr"; then
  printf 'FAIL setup: real enumerator could read the permission-denied fixture\n' >&2
  exit 1
fi
# Node names the real OS failure by its portable error code, rather than
# find's platform-dependent message. Also require the failing directory.
if ! grep -q 'EACCES' "$discovery_test_dir/discovery.stderr" || \
  ! grep -qF "$locked" "$discovery_test_dir/discovery.stderr" || \
  [ -s "$discovery_test_dir/discovery.stdout" ]; then
  printf 'FAIL setup: real enumeration failed for an unexpected reason or emitted a partial list\n' >&2
  cat "$discovery_test_dir/discovery.stderr" >&2
  exit 1
fi
printf 'control: '
cat "$discovery_test_dir/discovery.stderr"
check 'discovery preserves the real filesystem failure diagnostic' 2 \
  "$discovery_test_dir/unreadable" 'EACCES' "$locked" \
  'could not enumerate workflow files' '(exit 1)'

# The complete real directory has a bad filter. Returning only its valid file
# must not turn a failed enumeration into acceptance of that valid subset.
partial_root="$discovery_test_dir/partial"
mkdir -p "$partial_root/.github/workflows" "$discovery_test_dir/bin"
cp "$discovery_test_dir/valid/.github/workflows/ci.yml" "$partial_root/.github/workflows/ci.yml"
cp "$discovery_test_dir/invalid/.github/workflows/ci.yml" "$partial_root/.github/workflows/omitted.yaml"
check 'complete real discovery rejects the file omitted by the injection' 1 \
  "$partial_root" 'omitted.yaml' 'does not name the mainline'

cat >"$discovery_test_dir/bin/partial-node" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Enumerate real files first; inject only truncation and the final failure.
listing="$("$WORKFLOW_DISCOVERY_TEST_REAL_NODE" "$@")"
while IFS= read -r file; do
  case "$file" in
    */ci.yml) printf '%s\n' "$file" ;;
  esac
done <<<"$listing"
echo 'injected enumeration failure after a real filename' >&2
exit 23
SH
chmod +x "$discovery_test_dir/bin/partial-node"
if partial_output="$("$discovery_test_dir/bin/partial-node" "$ENUMERATOR" \
  "$partial_root/.github/workflows" \
  2>"$discovery_test_dir/partial.stderr")"; then
  partial_status=0
else
  partial_status=$?
fi
if [ "$partial_status" -ne 23 ] || [ "$partial_output" != "$partial_root/.github/workflows/ci.yml" ]; then
  printf 'FAIL setup: partial enumeration did not emit the real valid filename and exit 23\n' >&2
  exit 1
fi
printf 'control: partial enumeration emitted %s and exited %s\n' "$partial_output" "$partial_status"
WORKFLOW_TRIGGERS_NODE="$discovery_test_dir/bin/partial-node" check \
  'a failed enumeration cannot pass by checking its valid subset' 2 \
  "$partial_root" 'injected enumeration failure after a real filename' \
  'could not enumerate workflow files' '(exit 23)'

if [ "$failures" -ne 0 ]; then
  printf 'assert-workflow-triggers-discovery-test: %s case(s) failed.\n' "$failures"
  exit 1
fi
printf 'assert-workflow-triggers-discovery-test: all cases pass.\n'
