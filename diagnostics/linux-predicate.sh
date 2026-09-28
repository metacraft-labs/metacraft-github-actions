#!/usr/bin/env bash
# Real io-mon CLI/shim and the existing predicate suite. No mocks.
set -euo pipefail
mkdir -p test-logs/linux-predicate
logs="$PWD/test-logs/linux-predicate"
git log -1 --format='%H %s' | tee "$logs/source.txt"
uname -a | tee "$logs/host.txt"
bash scripts/build_shim.sh > "$logs/shim-build.log" 2>&1
nim c --hints:off --out:build/bin/io-mon cmd/io_mon_snoop.nim > "$logs/cli-build.log" 2>&1
nim c --hints:off --out:build/test-bin/predicate tests/linux/test_io_mon_inline_patch_predicate.nim > "$logs/predicate-build.log" 2>&1
nm -D build/test-bin/predicate > "$logs/exported-symbols.txt"
set +e
timeout -k 5 20 build/test-bin/predicate > "$logs/direct.log" 2>&1
direct_exit=$?
timeout -k 5 30 strace -ff -o "$logs/trace" build/bin/io-mon run --depfile "$logs/monitored.iomon" -- "$PWD/build/test-bin/predicate" > "$logs/monitored.log" 2>&1
monitored_exit=$?
set -e
printf 'direct_exit=%s\nmonitored_exit=%s\n' "$direct_exit" "$monitored_exit" | tee "$logs/result.txt"
cat "$logs/direct.log" "$logs/monitored.log"
# Diagnostic succeeds only if the ordinary test worked. A monitored timeout is
# retained as evidence, never mistaken for a passing product test.
test "$direct_exit" = 0

# Exercise production interposition after extracting its shared mapping policy.
# This is the existing real syscall fixture, including its architecture guard.
if [[ "$monitored_exit" != 0 ]]; then exit "$monitored_exit"; fi
nim c -r --hints:off tests/linux/test_io_mon_linux_inline_asm_exit_group.nim > "$logs/inline-exit-group.log" 2>&1
cat "$logs/inline-exit-group.log"

# Keep the real failing captures and inputs for attribution. Narrow this
# diagnostic to three cases; the ordinary product CI still runs the full suite.
mkdir -p "$logs/fixtures"
export TMPDIR="$logs/fixtures"
export IO_MON_DIAGNOSTIC_SAVE="$logs/saved-fixtures"
python3 - <<'PYPROBE'
from pathlib import Path
p = Path('tests/linux/test_io_mon_linux_stdio_ipc.nim')
s = p.read_text()
assert s.count('  removeDir(work)') == 1
p.write_text(s.replace('  removeDir(work)',
  '  copyDir(work, getEnv("IO_MON_DIAGNOSTIC_SAVE"))\n  removeDir(work)'))
PYPROBE
git diff -- tests/linux/test_io_mon_linux_stdio_ipc.nim > "$logs/preserve-fixtures.patch"
nim c --hints:off --out:build/test-bin/stdio-ipc tests/linux/test_io_mon_linux_stdio_ipc.nim > "$logs/stdio-build.log" 2>&1
set +e
timeout -k 10 120 build/test-bin/stdio-ipc \
  'stdio fopen/fread captures a file dependency and remains complete' \
  'relative writes follow a process chdir' \
  'raw libc syscall openat/read captures dependency' > "$logs/stdio-ipc.log" 2>&1
stdio_exit=$?
set -e
printf 'stdio_exit=%s\n' "$stdio_exit" >> "$logs/result.txt"
while IFS= read -r -d '' depfile; do
  build/bin/io-mon inspect "$depfile" --format json > "$depfile.inspect.json"
done < <(find "$logs/saved-fixtures" -name '*.iomon' -print0)
cat "$logs/stdio-ipc.log"
exit "$stdio_exit"
