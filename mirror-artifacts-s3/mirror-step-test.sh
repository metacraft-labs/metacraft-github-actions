#!/usr/bin/env bash
#
# mirror-step-test.sh — contract suite for mirror-artifacts-s3/mirror.sh.
#
# WHAT IS BEING GUARDED
# ---------------------
# The mirror is a non-blocking step: whatever happens to the upload, the step
# must END, exit 0, and leave nothing running. Before the bound existed, a
# stalled upload kept recorder CI jobs open for hours, and the runner later
# found the S3 client still running as an orphan. A surviving process matters
# even after the script exits, because the runner keeps a step open while
# anything still holds its stdout.
#
# CASES
# -----
#   1. not onboarded (no credential)     -> exit 0, skip message, client never run
#   2. client succeeds, directory path   -> exit 0, "Mirrored", --recursive and
#                                           the CLI connect/read timeouts passed
#   3. client succeeds, file path        -> exit 0, no --recursive
#   4. client exits 1                    -> exit 0, warning naming exit 1
#   5. client hangs (with a grandchild)  -> exit 0 within bound + grace, warning,
#                                           no process of the client tree left
#   6. client hangs and ignores SIGTERM  -> same, via the SIGKILL escalation
#   7. no aws on PATH, `nix shell … -c aws` hangs
#                                        -> same; nix's aws child is killed too
#   8. the step itself is cancelled (SIGTERM) while the client hangs
#                                        -> exit 0, client tree gone
#   9. malformed timeout-minutes         -> warning naming it; upload still runs
#  10. client exits but leaves a child   -> exit 0, the straggler is ended
#
# NEGATIVE CONTROLS
# -----------------
# Cases 2, 5, 6 and 10 are each paired with a MUTANT of the shipped script with one
# guard removed, and the suite requires the case to FAIL against it: no CLI
# timeouts (2), no separate process group (5: the grandchild survives), no
# deadline check (5: the script outlives the outer bound), no SIGKILL (6), no
# sweep of the group after the client exits (10: the straggler survives).
# Mutants are made by exact-line replacement, and `mutate` aborts if the line
# is not there.
#
# The script runs under `env -i` with a PATH of stub directories plus symlinks
# to the few coreutils it needs, so no real `aws` or `nix` can be reached.
# Output goes to a FILE, not a pipe: a command substitution would wait for
# every holder of the pipe, so a surviving client would hang the suite instead
# of failing a case.
#
# No network. Stock runner: bash, coreutils (incl. `timeout`), procps `ps`.
#
# Run:  bash mirror-artifacts-s3/mirror-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/mirror.sh"
BASH_BIN="$(command -v bash)"
WORK="$(mktemp -d)"

# Every stub appends the pids of its process tree here, so whatever a case or
# a mutant leaves behind is killed when the suite ends.
ALLPIDS="${WORK}/all.pids"
: >"${ALLPIDS}"
cleanup() {
  local p
  while read -r p; do kill -KILL "${p}" 2>/dev/null; done <"${ALLPIDS}"
  rm -rf "${WORK}"
}
trap cleanup EXIT

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

# Coreutils the script and stubs use, and nothing else.
CORE="${WORK}/core"
mkdir -p "${CORE}"
for t in sleep basename cat; do ln -s "$(command -v "${t}")" "${CORE}/${t}"; done

# make_aws <dir> <mode>: a stub `aws` that records its argv and pids.
#   ok        -> exit 0
#   fail      -> exit 1
#   hang      -> starts a grandchild `sleep`, then waits on it forever
#   hang-noterm -> the same with SIGTERM ignored (inherited by the grandchild)
#   orphan    -> starts a grandchild `sleep`, then exits 0 without waiting
make_aws() {
  local dir="$1" mode="$2"
  mkdir -p "${dir}"
  cat >"${dir}/aws" <<EOF
#!${BASH_BIN}
printf '%s\n' "\$*" >>"\${STUB_LOG}"
echo \$\$ >>"\${STUB_PIDS}"; echo \$\$ >>"${ALLPIDS}"
case "${mode}" in
  ok)   exit 0 ;;
  fail) exit 1 ;;
  hang-noterm) trap '' TERM ;;
esac
sleep 9999 &
echo \$! >>"\${STUB_PIDS}"; echo \$! >>"${ALLPIDS}"
[ "${mode}" = orphan ] && exit 0
wait
EOF
  chmod +x "${dir}/aws"
}

# A stub `nix` for `nix shell nixpkgs#awscli2 -c aws …`: it does NOT exec the
# client but runs it as a child and waits, the shape that leaves an orphan if
# only the direct child is killed.
make_nix() {
  local dir="$1" awsdir="$2"
  mkdir -p "${dir}"
  cat >"${dir}/nix" <<EOF
#!${BASH_BIN}
printf 'nix %s\n' "\$*" >>"\${STUB_LOG}"
echo \$\$ >>"\${STUB_PIDS}"; echo \$\$ >>"${ALLPIDS}"
shift 3   # shell nixpkgs#awscli2 -c
[ "\$1" = aws ] || exit 97
shift
"${awsdir}/aws" "\$@"
EOF
  chmod +x "${dir}/nix"
}

make_aws "${WORK}/aws-ok" ok
make_aws "${WORK}/aws-fail" fail
make_aws "${WORK}/aws-hang" hang
make_aws "${WORK}/aws-hang-noterm" hang-noterm
make_aws "${WORK}/aws-orphan" orphan
make_nix "${WORK}/nix-hang" "${WORK}/aws-hang"

mkdir -p "${WORK}/payload/sub"
echo log >"${WORK}/payload/sub/test.log"
echo log >"${WORK}/payload.log"

# run <script> <name> <stubdir> <path> [VAR=value…] -> RC, OUT, ELAPSED, LOG, PIDS
# The outer `timeout` only keeps a mutant from hanging the suite; it signals
# its own process group, which is not the one the script puts the client in.
run() {
  local script="$1" name="$2" stubdir="$3" path="$4"; shift 4
  LOG="${WORK}/${name}.log"; : >"${LOG}"
  PIDS="${WORK}/${name}.pids"; : >"${PIDS}"
  local outf="${WORK}/${name}.out" t0=${SECONDS}
  # The braces' 2>/dev/null only silences bash's "Killed" job report when the
  # outer bound fires on a mutant; the script's own output goes to ${outf}.
  { timeout -k 2 15 env -i PATH="${stubdir}:${CORE}" STUB_LOG="${LOG}" STUB_PIDS="${PIDS}" \
      AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s MCL_S3_ENDPOINT=http://127.0.0.1:9 \
      MCL_S3_PATH="${path}" MCL_S3_PREFIX="case/${name}" \
      MCL_S3_TIMEOUT_SECONDS=2 MCL_S3_KILL_GRACE_SECONDS=2 "$@" \
      "${BASH_BIN}" "${script}" >"${outf}" 2>&1 </dev/null; } 2>/dev/null
  RC=$?
  ELAPSED=$(( SECONDS - t0 ))
  OUT="$(cat "${outf}")"
}

# Pids from the last run that are still alive (zombies do not count: they hold
# no pipe and are only waiting to be reaped by whoever adopted them).
survivors() {
  local p st out=""
  sleep 0.3
  while read -r p; do
    st="$(ps -o stat= -p "${p}" 2>/dev/null)" || continue
    case "${st}" in Z*|"") ;; *) out="${out} ${p}" ;; esac
  done <"${PIDS}"
  echo "${out# }"
}

# mutate <from-line> <to-line> -> path of a mutated copy of the script
mutate() {
  local from="$1" to="$2" dst found=0 line
  dst="$(mktemp "${WORK}/mutant.XXXXXX")"
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line}" = "${from}" ]; then printf '%s\n' "${to}"; found=1
    else printf '%s\n' "${line}"; fi
  done <"${SCRIPT}" >"${dst}"
  if [ "${found}" -ne 1 ]; then
    echo "ABORT: mutate could not find the line to replace:" >&2
    echo "  ${from}" >&2
    exit 2
  fi
  echo "${dst}"
}

# A bounded case: exit 0, the timeout warning, ended within bound (2 s) +
# grace (2 s) + slack, and no survivor. Returns 0 when all of that holds.
bounded_ok() {
  [ "${RC}" -eq 0 ] && [ "${ELAPSED}" -le 8 ] \
    && [[ "${OUT}" == *"::warning title=S3 artifact mirror::upload did not finish within 2s"* ]] \
    && [ -z "$(survivors)" ]
}
explain() { echo "     rc=${RC} elapsed=${ELAPSED}s survivors=[$(survivors)]"; echo "${OUT}" | sed 's/^/     | /'; }

# --- 1. not onboarded -------------------------------------------------------
LOG="${WORK}/c1.log"; : >"${LOG}"
OUT="$(env -i PATH="${WORK}/aws-ok:${CORE}" STUB_LOG="${LOG}" STUB_PIDS=/dev/null \
        MCL_S3_PATH="${WORK}/payload" "${BASH_BIN}" "${SCRIPT}" 2>&1)"; RC=$?
if [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"not configured"* ]] && [ ! -s "${LOG}" ]; then
  pass "1 not onboarded: skipped, client never run"
else fail "1 not onboarded"; echo "${OUT}"; fi

# --- 2. success, directory --------------------------------------------------
case2() {
  run "$1" c2 "${WORK}/aws-ok" "${WORK}/payload"
  [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"Mirrored '${WORK}/payload' to s3://ci-artifacts/case/c2/"* ]] \
    && grep -q -- '--cli-connect-timeout 20 --cli-read-timeout 60 s3 cp --recursive ' "${LOG}"
}
if case2 "${SCRIPT}"; then pass "2 success (directory): mirrored, --recursive, CLI timeouts"
else fail "2 success (directory)"; explain; cat "${LOG}"; fi
if case2 "$(mutate '  --cli-connect-timeout 20 --cli-read-timeout 60 \' '  \')"; then
  fail "2 control: passes without the CLI timeouts"
else pass "2 control: fails without the CLI timeouts"; fi

# --- 3. success, file -------------------------------------------------------
run "${SCRIPT}" c3 "${WORK}/aws-ok" "${WORK}/payload.log"
if [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"Mirrored"* ]] && ! grep -q -- '--recursive' "${LOG}" \
   && grep -q -- "s3 cp ${WORK}/payload.log s3://ci-artifacts/case/c3/" "${LOG}"; then
  pass "3 success (file): no --recursive"
else fail "3 success (file)"; explain; cat "${LOG}"; fi

# --- 4. client fails --------------------------------------------------------
run "${SCRIPT}" c4 "${WORK}/aws-fail" "${WORK}/payload"
if [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"::warning title=S3 artifact mirror::upload failed with exit 1"* ]] \
   && [[ "${OUT}" != *"Mirrored"* ]]; then
  pass "4 client exits 1: warning, exit 0"
else fail "4 client exits 1"; explain; fi

# --- 5. client hangs --------------------------------------------------------
run "${SCRIPT}" c5 "${WORK}/aws-hang" "${WORK}/payload"
if bounded_ok; then pass "5 client hangs: stopped in ${ELAPSED}s, warning, exit 0, no survivor"
else fail "5 client hangs"; explain; fi
run "$(mutate 'set -m' ':')" c5m1 "${WORK}/aws-hang" "${WORK}/payload"
if bounded_ok; then fail "5 control: passes without a separate process group"
else pass "5 control: fails without a separate process group (survivors: $(survivors))"; fi
run "$(mutate '  if (( SECONDS - started >= limit_s )); then' '  if false; then')" c5m2 "${WORK}/aws-hang" "${WORK}/payload"
if bounded_ok; then fail "5 control: passes without the deadline check"
else pass "5 control: fails without the deadline check (rc=${RC} after ${ELAPSED}s)"; fi

# --- 6. client hangs and ignores SIGTERM ------------------------------------
run "${SCRIPT}" c6 "${WORK}/aws-hang-noterm" "${WORK}/payload"
if bounded_ok; then pass "6 client ignores SIGTERM: killed in ${ELAPSED}s, no survivor"
else fail "6 client ignores SIGTERM"; explain; fi
run "$(mutate '  signal_client KILL' '  :')" c6m "${WORK}/aws-hang-noterm" "${WORK}/payload"
if bounded_ok; then fail "6 control: passes without the SIGKILL escalation"
else pass "6 control: fails without the SIGKILL escalation (survivors: $(survivors))"; fi

# --- 7. nix fallback hangs --------------------------------------------------
run "${SCRIPT}" c7 "${WORK}/nix-hang" "${WORK}/payload"
if bounded_ok && grep -q '^nix shell nixpkgs#awscli2 -c aws --endpoint-url ' "${LOG}" \
   && [ "$(wc -l <"${PIDS}")" -eq 3 ]; then
  pass "7 nix shell … -c aws hangs: nix, aws and its child all stopped in ${ELAPSED}s"
else fail "7 nix fallback hangs"; explain; cat "${LOG}"; fi

# --- 8. the step is cancelled -----------------------------------------------
LOG="${WORK}/c8.log"; : >"${LOG}"; PIDS="${WORK}/c8.pids"; : >"${PIDS}"
env -i PATH="${WORK}/aws-hang:${CORE}" STUB_LOG="${LOG}" STUB_PIDS="${PIDS}" \
  AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s MCL_S3_ENDPOINT=http://127.0.0.1:9 \
  MCL_S3_PATH="${WORK}/payload" MCL_S3_TIMEOUT_SECONDS=60 MCL_S3_KILL_GRACE_SECONDS=2 \
  "${BASH_BIN}" "${SCRIPT}" >"${WORK}/c8.out" 2>&1 </dev/null &
step=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l <"${PIDS}")" -ge 2 ] && break; sleep 0.2; done
kill -TERM "${step}"
t0=${SECONDS}; wait "${step}"; RC=$?; ELAPSED=$(( SECONDS - t0 ))
OUT="$(cat "${WORK}/c8.out")"
if [ "${RC}" -eq 0 ] && [ "${ELAPSED}" -le 5 ] && [ -z "$(survivors)" ]; then
  pass "8 step cancelled: client tree stopped with it"
else fail "8 step cancelled"; explain; fi

# --- 9. malformed timeout-minutes -------------------------------------------
run "${SCRIPT}" c9 "${WORK}/aws-ok" "${WORK}/payload" MCL_S3_TIMEOUT_MINUTES=ten MCL_S3_TIMEOUT_SECONDS=
if [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"timeout-minutes 'ten' is not a positive integer; using 10"* ]] \
   && [[ "${OUT}" == *"Mirrored"* ]]; then
  pass "9 malformed timeout-minutes: warned, default used, upload ran"
else fail "9 malformed timeout-minutes"; explain; fi

# --- 10. client exits, leaving a child running -----------------------------
case10() {
  run "$1" c10 "${WORK}/aws-orphan" "${WORK}/payload"
  [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"Mirrored"* ]] && [ "${ELAPSED}" -le 4 ] \
    && [ "$(wc -l <"${PIDS}")" -eq 2 ] && [ -z "$(survivors)" ]
}
if case10 "${SCRIPT}"; then pass "10 client exits leaving a child: straggler ended, exit 0"
else fail "10 client exits leaving a child"; explain; fi
if case10 "$(mutate 'kill -s KILL -- "-$client_pid" 2>/dev/null' ':')"; then
  fail "10 control: passes without the post-exit group sweep"
else pass "10 control: fails without the post-exit group sweep (survivors: $(survivors))"; fi

echo
if [ "${fails}" -ne 0 ]; then echo "${fails} case(s) failed"; exit 1; fi
echo "all cases passed"
