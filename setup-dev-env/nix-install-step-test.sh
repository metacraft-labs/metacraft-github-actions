#!/usr/bin/env bash
#
# nix-install-step-test.sh — contract suite for decide-nix-install.sh and its
# wiring in setup-dev-env/action.yml.
#
# WHAT IS BEING GUARDED
# ---------------------
# Under `env-flavor: reprobuild`, a prebuilt `repro` on a host without Nix left
# the consumer's flake dev shell unable to start ("useFlakeDevShell needs nix
# on PATH"). setup-dev-env now installs Nix with setup-nix when no `nix` is on
# PATH on Linux or macOS. Installing it anywhere else is wrong too: over a
# host's own Nix, over a NixOS system Nix, or on Windows, which the flavor
# provisions without Nix.
#
# Cases (PATH is either a directory with a stub `nix` or one without; the
# host's own PATH and /etc are never consulted):
#   1. Linux, no nix                     -> install
#   2. macOS, no nix                     -> install
#   3. Linux, nix on PATH                -> present, no install
#   4. NixOS, nix on PATH                -> present, no install
#   5. NixOS, no nix                     -> nixos, no install, warning
#   6. Windows, no nix                   -> windows, no install
#   7. Windows, nix on PATH              -> windows, no install
# and every case exits 0 and prints its decision to the log and the summary;
# the install decision is a `::notice::`.
#
# NEGATIVE CONTROLS: cases 3, 5 and 6 are each paired with a MUTANT of the
# shipped script that lacks the guard the case depends on, and the suite
# requires the mutant to install where the script does not. `mutate` aborts
# when the line it replaces is not there, so a control that silently stopped
# mutating cannot pass.
#
# Wiring (case 8): the action runs the decision for the reprobuild flavor after
# the CLI install and before its Nix authentication step and its first
# `repro exec`; installs only on the `install-nix` output; uses setup-nix and
# hands it the caller's substituters and keys; and takes the NixOS signal from
# decide-tool-provisioning.sh, which runs earlier and prints `nixos-host`.
#
# Needs no network.
# Run:  bash setup-dev-env/nix-install-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/decide-nix-install.sh"
ACTION="${HERE}/action.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

BASH_BIN="$(command -v bash)"
# Each PATH holds only `bash` (the script uses builtins only) and, in WITH_NIX,
# a stub `nix`.
WITH_NIX="$TMP/with-nix"
NO_NIX="$TMP/no-nix"
mkdir -p "$WITH_NIX" "$NO_NIX"
ln -s "$BASH_BIN" "$WITH_NIX/bash"
ln -s "$BASH_BIN" "$NO_NIX/bash"
printf '#!/bin/sh\nexit 0\n' >"$WITH_NIX/nix"
chmod +x "$WITH_NIX/nix"

# run_step SCRIPT CASE_DIR PATH_DIR [VAR=value ...]: run the script in an empty
# environment; leaves $status, and the files out/log/summary in CASE_DIR.
run_step() {
  local script="$1" dir="$2" path="$3"
  shift 3
  mkdir -p "$dir"
  : >"$dir/out"
  : >"$dir/summary"
  status=0
  env -i PATH="$path" HOME="$dir" GITHUB_OUTPUT="$dir/out" GITHUB_STEP_SUMMARY="$dir/summary" \
    "$@" "$BASH_BIN" "$script" >"$dir/log" 2>&1 || status=$?
}
installs() { grep -q '^install-nix=true$' "$1/out"; }

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

expect() { # expect <label> <case-dir> <decision> <install true|false>
  local dir="$2" ok=1
  [ "$status" = 0 ] || ok=0
  grep -q "^nix-install-source=$3\$" "$dir/out" || ok=0
  grep -q "^install-nix=$4\$" "$dir/out" || ok=0
  [ -s "$dir/summary" ] || ok=0
  if [ "$4" = true ]; then
    grep -q "^::notice::setup-dev-env: Nix: $3:" "$dir/log" || ok=0
  else
    grep -q "^setup-dev-env: Nix: $3:" "$dir/log" || ok=0
  fi
  if [ "$ok" = 1 ]; then
    pass "$1"
  else
    fail "$1: status=$status out='$(cat "$dir/out")' $(cat "$dir/log")"
  fi
}

# 1. The defect: an ephemeral Linux VM without Nix.
run_step "$SCRIPT" "$TMP/c1" "$NO_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=false
expect "Linux without nix: Nix is installed, with a notice" "$TMP/c1" install true

# 2. A macOS runner without Nix. An empty NixOS signal counts as not NixOS.
run_step "$SCRIPT" "$TMP/c2" "$NO_NIX" RUNNER_OS=macOS MCL_NIXOS_HOST=
expect "macOS without nix: Nix is installed" "$TMP/c2" install true

# 3. A host that already has Nix (a persistent runner, or a source build of
# repro earlier in the job).
run_step "$SCRIPT" "$TMP/c3" "$WITH_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=false
expect "Linux with nix on PATH: nothing installed" "$TMP/c3" present false

# 3m. Control: without the PATH check, Nix is installed over the host's own.
mutate "$TMP/mutant-path.sh" 'elif command -v nix >/dev/null 2>&1; then' 'elif false; then'
run_step "$TMP/mutant-path.sh" "$TMP/c3m" "$WITH_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=false
if installs "$TMP/c3m"; then
  pass "control: without the PATH check, Nix IS installed over an existing one (case 3 is a real test)"
else
  fail "control: the mutant without the PATH check still passed case 3"
fi

# 4. A NixOS runner, as the persistent hosts are.
run_step "$SCRIPT" "$TMP/c4" "$WITH_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=true
expect "NixOS with nix on PATH: nothing installed" "$TMP/c4" present false
if grep -q '::warning::' "$TMP/c4/log"; then
  fail "a warning was printed although nix is on PATH: $(cat "$TMP/c4/log")"
else
  pass "no warning when nix is on PATH"
fi

# 5. NixOS whose PATH lacks nix: the system Nix is not reinstalled.
run_step "$SCRIPT" "$TMP/c5" "$NO_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=true
expect "NixOS without nix on PATH: nothing installed" "$TMP/c5" nixos false
if grep -q '^::warning::setup-dev-env: this NixOS runner has no `nix` on PATH' "$TMP/c5/log"; then
  pass "NixOS without nix on PATH: a warning says so"
else
  fail "NixOS without nix on PATH printed no warning: $(cat "$TMP/c5/log")"
fi

# 5m. Control: without the NixOS check, a second Nix is installed on NixOS.
mutate "$TMP/mutant-nixos.sh" 'elif [ "${MCL_NIXOS_HOST:-}" = true ]; then' 'elif false; then'
run_step "$TMP/mutant-nixos.sh" "$TMP/c5m" "$NO_NIX" RUNNER_OS=Linux MCL_NIXOS_HOST=true
if installs "$TMP/c5m"; then
  pass "control: without the NixOS check, Nix IS installed on NixOS (case 5 is a real test)"
else
  fail "control: the mutant without the NixOS check still passed case 5"
fi

# 6. Windows has no Nix and the flavor does not use one there.
run_step "$SCRIPT" "$TMP/c6" "$NO_NIX" RUNNER_OS=Windows MCL_NIXOS_HOST=false
expect "Windows without nix: nothing installed" "$TMP/c6" windows false

# 6m. Control: without the Windows check, Windows would be sent to setup-nix.
mutate "$TMP/mutant-windows.sh" 'if [ "${RUNNER_OS:-}" = Windows ]; then' 'if false; then'
run_step "$TMP/mutant-windows.sh" "$TMP/c6m" "$NO_NIX" RUNNER_OS=Windows MCL_NIXOS_HOST=false
if installs "$TMP/c6m"; then
  pass "control: without the Windows check, Windows IS sent to setup-nix (case 6 is a real test)"
else
  fail "control: the mutant without the Windows check still passed case 6"
fi

# 7. Windows wins over a nix on PATH (a WSL shim, say).
run_step "$SCRIPT" "$TMP/c7" "$WITH_NIX" RUNNER_OS=Windows MCL_NIXOS_HOST=false
expect "Windows with nix on PATH: nothing installed" "$TMP/c7" windows false

# 8. Wiring in action.yml.
line_of() { grep -n -F -- "$1" "$ACTION" | head -n 1 | cut -d: -f1; }
step_block() { # step_block <line>: the step starting at <line>, up to the next step; empty when <line> is
  [ -n "$1" ] || return 0
  awk -v start="$1" 'NR > start && /^    - name:/ { exit } NR >= start { print }' "$ACTION"
}
provisioning_line="$(line_of 'run: bash "${GITHUB_ACTION_PATH}/decide-tool-provisioning.sh"')"
cli_line="$(line_of '- name: Install the repro CLI (reprobuild)')"
decide_name_line="$(line_of '- name: Decide whether the dev env needs Nix installed (reprobuild)')"
install_name_line="$(line_of '- name: Install Nix for the dev env (reprobuild)')"
auth_line="$(line_of '- name: Configure Nix authentication (reprobuild)')"
witness_line="$(line_of 'if repro exec -- bash -c')"
order_ok=0
if [ -n "$provisioning_line" ] && [ -n "$cli_line" ] && [ -n "$decide_name_line" ] &&
  [ -n "$install_name_line" ] && [ -n "$auth_line" ] && [ -n "$witness_line" ] &&
  [ "$provisioning_line" -lt "$cli_line" ] && [ "$cli_line" -lt "$decide_name_line" ] &&
  [ "$decide_name_line" -lt "$install_name_line" ] && [ "$install_name_line" -lt "$auth_line" ] &&
  [ "$auth_line" -lt "$witness_line" ]; then
  order_ok=1
fi
if [ "$order_ok" = 1 ]; then
  pass "action.yml: tool-provisioning < CLI install < decision < install < Nix auth < repro exec"
else
  fail "action.yml order: provisioning=$provisioning_line cli=$cli_line decide=$decide_name_line install=$install_name_line auth=$auth_line witness=$witness_line"
fi

decide_block="$(step_block "$decide_name_line")"
install_block="$(step_block "$install_name_line")"
if printf '%s\n' "$decide_block" | grep -q -F "if: \${{ inputs.env-flavor == 'reprobuild' }}" &&
  printf '%s\n' "$decide_block" | grep -q -F 'MCL_NIXOS_HOST: ${{ steps.tool-provisioning.outputs.nixos-host }}' &&
  printf '%s\n' "$decide_block" | grep -q -F 'run: bash "${GITHUB_ACTION_PATH}/decide-nix-install.sh"' &&
  printf '%s\n' "$decide_block" | grep -q -F 'id: nix-install'; then
  pass "action.yml: the decision runs for the reprobuild flavor with the NixOS signal"
else
  fail "action.yml decision step: $decide_block"
fi
if printf '%s\n' "$install_block" | grep -q -F "if: \${{ inputs.env-flavor == 'reprobuild' && steps.nix-install.outputs.install-nix == 'true' }}" &&
  printf '%s\n' "$install_block" | grep -q -F 'uses: metacraft-labs/metacraft-github-actions/setup-nix@' &&
  printf '%s\n' "$install_block" | grep -q -F 'substituters: ${{ inputs.substituters }}' &&
  printf '%s\n' "$install_block" | grep -q -F 'trusted-public-keys: ${{ inputs.trusted-public-keys }}' &&
  printf '%s\n' "$install_block" | grep -q -F 'attic-token: ${{ inputs.attic-token }}'; then
  pass "action.yml: setup-nix runs only on install-nix, with the caller's substituters and keys"
else
  fail "action.yml install step: $install_block"
fi

# The NixOS signal must exist: decide-tool-provisioning.sh prints it on every
# path, including when a caller's own mode settles the decision.
ETC="$TMP/etc"
mkdir -p "$ETC"
: >"$ETC/NIXOS"
mkdir -p "$TMP/c9"
: >"$TMP/c9/out"
env -i PATH="$WITH_NIX" HOME="$TMP/c9" GITHUB_OUTPUT="$TMP/c9/out" MCL_NIXOS_MARKER="$ETC/NIXOS" \
  MCL_OS_RELEASE="$TMP/missing" REPRO_TOOL_PROVISIONING=path \
  "$BASH_BIN" "${HERE}/decide-tool-provisioning.sh" >"$TMP/c9/log" 2>&1
mkdir -p "$TMP/c10"
: >"$TMP/c10/out"
env -i PATH="$WITH_NIX" HOME="$TMP/c10" GITHUB_OUTPUT="$TMP/c10/out" MCL_NIXOS_MARKER="$TMP/missing" \
  MCL_OS_RELEASE="$TMP/missing" "$BASH_BIN" "${HERE}/decide-tool-provisioning.sh" >"$TMP/c10/log" 2>&1
if grep -q '^nixos-host=true$' "$TMP/c9/out" && grep -q '^nixos-host=false$' "$TMP/c10/out"; then
  pass "decide-tool-provisioning.sh reports nixos-host, also when a caller's mode is set"
else
  fail "nixos-host output: NixOS='$(cat "$TMP/c9/out")' other='$(cat "$TMP/c10/out")'"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all cases passed"
