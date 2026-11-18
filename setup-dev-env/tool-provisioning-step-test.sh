#!/usr/bin/env bash
#
# tool-provisioning-step-test.sh — contract suite for
# decide-tool-provisioning.sh.
#
# WHAT IS BEING GUARDED
# ---------------------
# On a NixOS runner, the generic-Linux tool tarballs that `repro`'s non-Nix
# provisioning modes fall back to cannot run (NixOS's loader stub refuses
# them), so setup-dev-env exports REPRO_TOOL_PROVISIONING=nix there. Exporting
# it anywhere else would override projects' declared modes for no reason, and
# overriding a caller's own choice would take a decision away from the job.
#
# Cases (the NixOS marker and os-release paths are overridden into a scratch
# directory; the host's /etc is never read):
#   1. /etc/NIXOS present                   -> nix exported, source nixos
#   2. os-release ID=nixos (no marker)      -> nix exported
#   3. os-release ID="nixos" (quoted, CRLF) -> nix exported
#   4. not NixOS (ID=ubuntu, ID_LIKE=nixos) -> nothing exported, source not-nixos
#   5. neither file exists                  -> nothing exported, job not failed
#   6. a caller's REPRO_TOOL_PROVISIONING on NixOS -> left alone, source caller
#   7. an empty caller value on NixOS       -> treated as unset, nix exported
#   8. NixOS without `nix` on PATH          -> still exported, with a warning
# and every case exits 0 and prints its decision to the log and summary; the
# NixOS decision is a `::notice::`.
#
# NEGATIVE CONTROLS: cases 4 and 6 are paired with MUTANTS of the shipped
# script — one that accepts any os-release, one that ignores the caller's
# value — and the suite requires each case to FAIL against its mutant. `mutate`
# aborts when the line it is told to replace is not there, so a control that
# silently stopped mutating cannot pass.
#
# Needs no network.
# Run:  bash setup-dev-env/tool-provisioning-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/decide-tool-provisioning.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# A PATH with a stub `nix`, and one without any (case 8). Both carry the
# coreutils the script's bash needs; the script itself uses builtins only.
STUB_DIR="$TMP/stubbin"
mkdir -p "$STUB_DIR"
printf '#!/bin/sh\nexit 0\n' >"$STUB_DIR/nix"
chmod +x "$STUB_DIR/nix"
BASH_BIN="$(command -v bash)"
NO_NIX_DIR="$TMP/no-nix-bin"
mkdir -p "$NO_NIX_DIR"
ln -s "$BASH_BIN" "$NO_NIX_DIR/bash"

ETC="$TMP/etc"
mkdir -p "$ETC"
MISSING="$TMP/does-not-exist"

# run_step SCRIPT CASE_DIR [VAR=value ...]: run the script in an empty
# environment of its own; leaves $status, and the files env/out/log in CASE_DIR.
run_step() {
  local script="$1" dir="$2"
  shift 2
  mkdir -p "$dir"
  : >"$dir/env"
  : >"$dir/out"
  : >"$dir/summary"
  status=0
  env -i PATH="$STUB_DIR:$PATH" HOME="$dir" GITHUB_ENV="$dir/env" GITHUB_OUTPUT="$dir/out" \
    GITHUB_STEP_SUMMARY="$dir/summary" "$@" "$BASH_BIN" "$script" >"$dir/log" 2>&1 || status=$?
}
exported() { cat "$1/env"; }
source_is() { grep -q "^tool-provisioning-source=$2\$" "$1/out"; }

mutate() { # mutate <out> <exact line to replace> <replacement>
  local out="$1" from="$2" to="$3" line found=0
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$from" ]; then
      printf '%s\n' "$to" >>"$out"
      found=1
    else
      printf '%s\n' "$line" >>"$out"
    fi
  done <"$SCRIPT"
  [ "$found" = 1 ] || {
    echo "mutate: the line to replace is not in $SCRIPT: $from" >&2
    exit 1
  }
}

expect_nix() { # expect_nix <label> <case-dir>
  local dir="$2"
  if [ "$status" = 0 ] && [ "$(exported "$dir")" = "REPRO_TOOL_PROVISIONING=nix" ] &&
    source_is "$dir" nixos && grep -q '^tool-provisioning=nix$' "$dir/out" &&
    grep -q '^::notice::setup-dev-env: tool provisioning: nixos' "$dir/log" && [ -s "$dir/summary" ]; then
    pass "$1"
  else
    fail "$1: status=$status env='$(exported "$dir")' $(cat "$dir/log")"
  fi
}

expect_none() { # expect_none <label> <case-dir> <source>
  local dir="$2"
  if [ "$status" = 0 ] && [ -z "$(exported "$dir")" ] && source_is "$dir" "$3" &&
    grep -q "^setup-dev-env: tool provisioning: $3" "$dir/log" && [ -s "$dir/summary" ]; then
    pass "$1"
  else
    fail "$1: status=$status env='$(exported "$dir")' $(cat "$dir/log")"
  fi
}

# 1. The /etc/NIXOS marker alone.
: >"$ETC/NIXOS"
run_step "$SCRIPT" "$TMP/c1" MCL_NIXOS_MARKER="$ETC/NIXOS" MCL_OS_RELEASE="$MISSING"
expect_nix "/etc/NIXOS present: REPRO_TOOL_PROVISIONING=nix exported, with a notice" "$TMP/c1"

# 2. os-release ID=nixos, no marker.
printf 'NAME=NixOS\nID=nixos\nVERSION_ID="25.11"\n' >"$ETC/os-release-nixos"
run_step "$SCRIPT" "$TMP/c2" MCL_NIXOS_MARKER="$MISSING" MCL_OS_RELEASE="$ETC/os-release-nixos"
expect_nix "os-release ID=nixos: REPRO_TOOL_PROVISIONING=nix exported" "$TMP/c2"

# 3. Quoted value with a CRLF terminator.
printf 'NAME="NixOS"\r\nID="nixos"\r\n' >"$ETC/os-release-quoted"
run_step "$SCRIPT" "$TMP/c3" MCL_NIXOS_MARKER="$MISSING" MCL_OS_RELEASE="$ETC/os-release-quoted"
expect_nix "os-release ID=\"nixos\" (quoted, CRLF): nix exported" "$TMP/c3"

# 4. Another distribution. ID_LIKE mentioning nixos must not count: only ID does.
printf 'NAME=Ubuntu\nID_LIKE=nixos\nID=ubuntu\n' >"$ETC/os-release-ubuntu"
run_step "$SCRIPT" "$TMP/c4" MCL_NIXOS_MARKER="$MISSING" MCL_OS_RELEASE="$ETC/os-release-ubuntu"
expect_none "not NixOS: nothing exported, the project's mode applies" "$TMP/c4" not-nixos

# 4m. Control: a script that takes any os-release for NixOS exports nix on Ubuntu.
mutate "$TMP/mutant-any-os.sh" '      [ "$value" = nixos ] && return 0' '      return 0'
run_step "$TMP/mutant-any-os.sh" "$TMP/c4m" MCL_NIXOS_MARKER="$MISSING" MCL_OS_RELEASE="$ETC/os-release-ubuntu"
if [ -n "$(exported "$TMP/c4m")" ]; then
  pass "control: without the ID check, Ubuntu IS taken for NixOS (case 4 is a real test)"
else
  fail "control: the mutant without the ID check still passed case 4"
fi

# 5. Neither file (macOS, Windows Git Bash, a container without os-release).
run_step "$SCRIPT" "$TMP/c5" MCL_NIXOS_MARKER="$MISSING" MCL_OS_RELEASE="$MISSING"
expect_none "no marker, no os-release: nothing exported, job not failed" "$TMP/c5" not-nixos

# 6. A caller's own choice on NixOS is left alone.
run_step "$SCRIPT" "$TMP/c6" MCL_NIXOS_MARKER="$ETC/NIXOS" MCL_OS_RELEASE="$ETC/os-release-nixos" \
  REPRO_TOOL_PROVISIONING=path
expect_none "a caller's REPRO_TOOL_PROVISIONING=path on NixOS is left alone" "$TMP/c6" caller

# 6m. Control: a script that ignores the caller's value overrides it on NixOS.
mutate "$TMP/mutant-caller.sh" 'if [ -n "${REPRO_TOOL_PROVISIONING:-}" ]; then' 'if false; then'
run_step "$TMP/mutant-caller.sh" "$TMP/c6m" MCL_NIXOS_MARKER="$ETC/NIXOS" MCL_OS_RELEASE="$MISSING" \
  REPRO_TOOL_PROVISIONING=path
if [ -n "$(exported "$TMP/c6m")" ]; then
  pass "control: without the caller check, the caller's value IS overridden (case 6 is a real test)"
else
  fail "control: the mutant without the caller check still passed case 6"
fi

# 7. An empty value counts as unset, as it does in repro.
run_step "$SCRIPT" "$TMP/c7" MCL_NIXOS_MARKER="$ETC/NIXOS" MCL_OS_RELEASE="$MISSING" REPRO_TOOL_PROVISIONING=
expect_nix "an empty REPRO_TOOL_PROVISIONING on NixOS is treated as unset" "$TMP/c7"

# 8. NixOS with no `nix` on PATH: the mode still stands, and the log warns.
mkdir -p "$TMP/c8"
: >"$TMP/c8/env"
: >"$TMP/c8/out"
: >"$TMP/c8/summary"
status=0
env -i PATH="$NO_NIX_DIR" HOME="$TMP/c8" GITHUB_ENV="$TMP/c8/env" GITHUB_OUTPUT="$TMP/c8/out" \
  GITHUB_STEP_SUMMARY="$TMP/c8/summary" MCL_NIXOS_MARKER="$ETC/NIXOS" MCL_OS_RELEASE="$MISSING" \
  "$BASH_BIN" "$SCRIPT" >"$TMP/c8/log" 2>&1 || status=$?
if [ "$status" = 0 ] && [ "$(exported "$TMP/c8")" = "REPRO_TOOL_PROVISIONING=nix" ] &&
  grep -q '^::warning::.*no `nix` is on PATH' "$TMP/c8/log"; then
  pass "NixOS without nix on PATH: still exported, with a warning"
else
  fail "no nix on PATH: status=$status env='$(exported "$TMP/c8")' $(cat "$TMP/c8/log")"
fi
if grep -q '::warning::' "$TMP/c1/log"; then
  fail "a warning was printed although nix is on PATH: $(cat "$TMP/c1/log")"
else
  pass "no warning when nix is on PATH"
fi

# 9. Wiring: $GITHUB_ENV reaches later steps only, so the action must run the
# script, under the reprobuild flavor, before its own first `repro` command
# (the repro.lock sibling provisioning and the `repro exec` witness).
ACTION="${HERE}/action.yml"
line_of() { grep -n -F -- "$1" "$ACTION" | head -n 1 | cut -d: -f1; }
decide_line="$(line_of 'run: bash "${GITHUB_ACTION_PATH}/decide-tool-provisioning.sh"')"
lock_line="$(line_of 'run: bash "${GITHUB_ACTION_PATH}/provision-siblings-from-lock.sh"')"
witness_line="$(line_of "if repro exec -- bash -c")"
if [ -n "$decide_line" ] && [ -n "$lock_line" ] && [ -n "$witness_line" ] &&
  [ "$decide_line" -lt "$lock_line" ] && [ "$decide_line" -lt "$witness_line" ] &&
  sed -n "$((decide_line - 4)),${decide_line}p" "$ACTION" |
  grep -q -F "if: \${{ inputs.env-flavor == 'reprobuild' }}"; then
  pass "action.yml runs the decision for the reprobuild flavor before its first repro command"
else
  fail "action.yml wiring: decide=$decide_line lock=$lock_line witness=$witness_line"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all cases passed"
