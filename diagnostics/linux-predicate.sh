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
