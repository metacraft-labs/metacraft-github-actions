#!/usr/bin/env bash
#
# ensure-host-decompressors-step-test.sh — contract suite for
# ensure-host-decompressors.sh.
#
# WHAT IS BEING GUARDED
# ---------------------
# `repro` provisions a declared tool from a tarball by running the host `tar`,
# which runs `gzip` / `xz` / `bzip2` as a child process. On runners whose PATH
# is a Nix profile without them, `repro build` fails long after setup reported
# success, with `tar (child): xz: Cannot exec`. The script either puts the
# missing tools on PATH or fails up front, naming them.
#
# CASES
# -----
#   1. every tool present            -> exit 0, PATH file untouched, nix never run
#   2. xz missing, nix provides it   -> exit 0, its bin/ appended to GITHUB_PATH
#   3. xz missing, no nix            -> exit 1, error names xz
#   4. nix build succeeds, but the output has no bin/xz
#                                    -> exit 1, error names xz
#   5. nix build fails               -> exit 1, error names xz
#   6. xz AND bzip2 missing, no nix  -> exit 1, error names BOTH
#
# NEGATIVE CONTROLS
# -----------------
# Cases 1, 2, 4 and 6 are each paired with a MUTANT of the shipped script with
# one guard removed, and the suite requires the case to FAIL against it. A case
# that passes against both the real script and one with its guard deleted is
# not testing anything. Mutants are made by exact-line replacement, and
# `mutate` aborts if the line is not there: a control that silently stopped
# mutating would be the same defect one level up.
#
# The script under test is run with `env -i` and a PATH made of stub
# directories only, so "missing" means missing — nothing from the machine
# running the suite can stand in for a tool the case says is absent.
#
# No network. Stock runner: bash and coreutils.
#
# Run:  bash setup-dev-env/ensure-host-decompressors-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/ensure-host-decompressors.sh"
BASH_BIN="$(command -v bash)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

# A directory holding a stub executable for each named tool.
tooldir() {
  local d="$1"; shift
  mkdir -p "${d}"
  local t
  for t in "$@"; do
    printf '#!%s\nexit 0\n' "${BASH_BIN}" >"${d}/${t}"
    chmod +x "${d}/${t}"
  done
}

# A stub `nix`. Uses bash builtins only: it runs under the same stripped PATH
# as the script. MODE is fixed when the stub is written.
#   ok    -> prints the pre-built output for the requested attribute
#   nobin -> prints an output directory with no bin/ in it
#   fail  -> exits non-zero
make_nix() {
  local path="$1" mode="$2" log="$3" outroot="$4"
  cat >"${path}" <<EOF
#!${BASH_BIN}
echo "\$*" >>"${log}"
attr="\${@: -1}"; attr="\${attr#*#}"
case "${mode}" in
  ok)    echo "${outroot}/\${attr}-doc"; echo "${outroot}/\${attr}" ;;
  nobin) echo "${outroot}/\${attr}-nobin" ;;
  fail)  echo "error: attribute build failed" >&2; exit 1 ;;
esac
EOF
  chmod +x "${path}"
}

# Pre-built nix outputs: `<attr>` carries bin/<tool>; `<attr>-doc` and
# `<attr>-nobin` do not. `-doc` is printed first so a script that took the
# first printed path would pick an output without the tool.
outroot="${WORK}/store"
tooldir "${outroot}/xz/bin" xz
tooldir "${outroot}/bzip2/bin" bzip2
mkdir -p "${outroot}/xz-doc/share" "${outroot}/xz-nobin/share"
mkdir -p "${outroot}/bzip2-doc/share"

# run <script> <case-name> <PATH> <nix-or-empty>  -> sets RC, OUT, GP, NIXLOG
run() {
  local script="$1" name="$2" path="$3" nix="$4"
  GP="${WORK}/${name}.github_path"; : >"${GP}"
  NIXLOG="${WORK}/${name}.nixlog"; : >"${NIXLOG}"
  OUT="$(env -i PATH="${path}" GITHUB_PATH="${GP}" \
          ENSURE_HOST_TOOLS_NIX="${nix}" \
          "${BASH_BIN}" "${script}" 2>&1)"
  RC=$?
}

# mutate <from-line> <to-line> -> path of a mutated copy of the script
mutate() {
  local from="$1" to="$2" dst
  dst="$(mktemp "${WORK}/mutant.XXXXXX")"
  local found=0 line
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line}" = "${from}" ]; then
      printf '%s\n' "${to}"; found=1
    else
      printf '%s\n' "${line}"
    fi
  done <"${SCRIPT}" >"${dst}"
  if [ "${found}" -ne 1 ]; then
    echo "ABORT: mutate could not find the line to replace:" >&2
    echo "  ${from}" >&2
    exit 2
  fi
  echo "${dst}"
}

all="${WORK}/all";   tooldir "${all}" tar gzip xz bzip2
noxz="${WORK}/noxz"; tooldir "${noxz}" tar gzip bzip2
two="${WORK}/two";   tooldir "${two}" tar gzip

nix_ok="${WORK}/nix-ok";       make_nix "${nix_ok}" ok "${WORK}/nix-ok.log" "${outroot}"
nix_nobin="${WORK}/nix-nobin"; make_nix "${nix_nobin}" nobin "${WORK}/nix-nobin.log" "${outroot}"
nix_fail="${WORK}/nix-fail";   make_nix "${nix_fail}" fail "${WORK}/nix-fail.log" "${outroot}"

# ---- case predicates: return 0 when the case's contract holds ------------

case1() { # every tool present
  : >"${WORK}/nix-ok.log"
  run "$1" case1 "${all}" "${nix_ok}"
  [ "${RC}" -eq 0 ] && [ ! -s "${GP}" ] && [ ! -s "${WORK}/nix-ok.log" ]
}
case2() { # xz missing, nix provides it
  run "$1" case2 "${noxz}" "${nix_ok}"
  [ "${RC}" -eq 0 ] && grep -qxF "${outroot}/xz/bin" "${GP}"
}
case3() { # xz missing, no nix
  run "$1" case3 "${noxz}" ""
  [ "${RC}" -eq 1 ] && [[ "${OUT}" == *"::error::"*"xz"* ]]
}
case4() { # nix succeeds without providing bin/xz
  run "$1" case4 "${noxz}" "${nix_nobin}"
  [ "${RC}" -eq 1 ] && [[ "${OUT}" == *"::error::"*"xz"* ]]
}
case5() { # nix build fails
  run "$1" case5 "${noxz}" "${nix_fail}"
  [ "${RC}" -eq 1 ] && [[ "${OUT}" == *"::error::"*"xz"* ]]
}
case6() { # two missing, no nix: both named
  run "$1" case6 "${two}" ""
  [ "${RC}" -eq 1 ] && [[ "${OUT}" == *"::error::"*"xz"* ]] \
    && [[ "${OUT}" == *"::error::"*"bzip2"* ]]
}

check() { # check <name> <description>
  if "$1" "${SCRIPT}"; then pass "$2"; else fail "$2"; echo "${OUT}" | sed 's/^/    | /'; fi
}
control() { # control <case> <description> <from> <to>
  local m; m="$(mutate "$3" "$4")" || exit 2
  if "$1" "${m}"; then
    fail "negative control: $2 — the case still passes with that guard removed"
  else
    pass "negative control: $2"
  fi
}

check case1 "1. every tool present: nothing appended, nix never run"
check case2 "2. xz missing, nix provides it: its bin/ reaches GITHUB_PATH"
check case3 "3. xz missing, no nix: fails naming xz"
check case4 "4. nix succeeds but yields no bin/xz: fails naming xz"
check case5 "5. nix build fails: fails naming xz"
check case6 "6. xz and bzip2 missing, no nix: fails naming both"

control case1 "the PATH presence check" \
  '  if command -v "${tool}" >/dev/null 2>&1; then' \
  '  if false; then'
control case2 "appending the provided bin/ to GITHUB_PATH" \
  '      echo "${p}/bin" >>"${GITHUB_PATH}"' \
  '      :'
control case4 "re-checking PATH instead of trusting nix build's exit status" \
  '  command -v "${tool}" >/dev/null 2>&1 || still+=("${tool}")' \
  '  :'
control case6 "naming every missing tool, not just the first" \
  '  echo "::error::ensure-host-decompressors: not on PATH and could not be provided: ${still[*]}. repro provisions tools from tarballs with the host tar, which runs these as child processes; without them a later '"'"'repro build'"'"' fails with '"'"'tar (child): <tool>: Cannot exec'"'"'. Put them on the runner'"'"'s PATH, or make nix available to this step."' \
  '  echo "::error::ensure-host-decompressors: not on PATH and could not be provided: ${still[0]}."'

echo
if [ "${fails}" -ne 0 ]; then
  echo "${fails} failure(s)"
  exit 1
fi
echo "all ensure-host-decompressors cases and controls passed"
