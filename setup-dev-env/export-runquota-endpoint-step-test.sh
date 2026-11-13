#!/usr/bin/env bash
#
# export-runquota-endpoint-step-test.sh — contract suite for
# export-runquota-endpoint.sh.
#
# WHAT IS BEING GUARDED
# ---------------------
# Later steps of a job must draw on the HOST's RunQuota daemon, not start a
# private one. The script exports RUNQUOTA_SOCKET when a daemon answers on the
# host's rendezvous socket, and must NEVER fail the job: on a runner with no
# RunQuota service it exports nothing and `repro` falls back to the user's
# shared daemon. Pointing every later step at a socket that does not answer
# would turn that working fallback into a failure, so a stale socket file (the
# leftover of a killed daemon) must not be exported either.
#
# Cases (rendezvous paths are overridden into a scratch directory; the real
# /run is neither read nor written):
#   1. a daemon answers            -> exported, source `host`
#   2. no socket at all            -> nothing exported, exit 0, source `absent`
#   3. a socket file, nobody home  -> nothing exported, exit 0, source `stale`
#   4. no runquota client on PATH  -> nothing exported (cannot verify), exit 0
#   5. a caller's RUNQUOTA_SOCKET  -> left alone, source `caller`
#   6. the runquota-socket input   -> exported as given, source `input`
#   7. no rendezvous candidates (Windows) -> nothing exported, source `windows`
# and every case prints its decision to the log and the job summary.
# plus, when the real `runquota` and `runquotad` are available, case 1 again
# against a real daemon (reported SKIPPED, never as a pass, when they are not).
#
# The client in cases 1-6 is a stub whose `status` succeeds only while a marker
# file named after the socket exists: the suite must run on a stock runner that
# has no RunQuota. A stub proves the script's logic; the real-daemon case is
# what proves the script and the real client agree.
#
# NEGATIVE CONTROL: the stale-socket case is paired with a MUTANT of the shipped
# script whose `answers` check always succeeds, and the suite requires that case
# to FAIL against the mutant. `mutate` aborts when the line it is told to
# replace is not there, so a control that silently stopped mutating cannot pass.
#
# Needs python3 (to bind a real unix socket) and no network.
# Run:  bash setup-dev-env/export-runquota-endpoint-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/export-runquota-endpoint.sh"
TMP="$(mktemp -d)"
daemon_pid=""
cleanup() {
  # Stop only the daemon started here, only while the PID still names a process
  # under this suite's directory; never by name.
  if [ -n "$daemon_pid" ] && [ -r "/proc/$daemon_pid/cmdline" ] &&
    tr '\0' ' ' <"/proc/$daemon_pid/cmdline" | grep -qF -- "$TMP/"; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "${TMP:?}"
}
trap cleanup EXIT

failures=0
skips=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
skip() {
  printf 'SKIP %s\n' "$1"
  skips=$((skips + 1))
}

command -v python3 >/dev/null || {
  echo "FAIL python3 is required" >&2
  exit 1
}

# A unix socket FILE that nobody listens on: bound, then closed. This is what a
# killed daemon leaves behind.
make_socket_file() {
  python3 - "$1" <<'PY'
import os, socket, sys
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.close()
assert os.path.exists(path)
PY
}

# The stub client: `status` succeeds while "$RUNQUOTA_SOCKET.alive" exists.
STUB_DIR="$TMP/stubbin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/runquota" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = status ] && [ -e "${RUNQUOTA_SOCKET:-/nonexistent}.alive" ]
EOS
chmod +x "$STUB_DIR/runquota"

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
  env -i PATH="$PATH" HOME="$dir" GITHUB_ENV="$dir/env" GITHUB_OUTPUT="$dir/out" \
    GITHUB_STEP_SUMMARY="$dir/summary" "$@" bash "$script" >"$dir/log" 2>&1 || status=$?
}
exported() { cat "$1/env"; }

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

sockdir="$TMP/run"
mkdir -p "$sockdir"
SOCK="$sockdir/runquotad.sock"

# 2. No socket at all.
run_step "$SCRIPT" "$TMP/c2" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ -z "$(exported "$TMP/c2")" ] && grep -q '^runquota-endpoint-source=absent$' "$TMP/c2/out"; then
  pass "no socket: nothing exported, job not failed, source absent"
else
  fail "no socket: status=$status env='$(exported "$TMP/c2")' $(cat "$TMP/c2/log")"
fi

# 3. A socket file nobody answers on.
make_socket_file "$SOCK"
run_step "$SCRIPT" "$TMP/c3" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ -z "$(exported "$TMP/c3")" ] && grep -q '^runquota-endpoint-source=stale$' "$TMP/c3/out"; then
  pass "stale socket: nothing exported, job not failed, source stale"
else
  fail "stale socket: status=$status env='$(exported "$TMP/c3")' $(cat "$TMP/c3/log")"
fi

# 3m. The control: a script that treats any socket file as an answer exports it.
mutate "$TMP/mutant.sh" '  RUNQUOTA_SOCKET="$1" "$CLI" status >/dev/null 2>&1' '  true'
run_step "$TMP/mutant.sh" "$TMP/c3m" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" MCL_RUNQUOTA_BIN="$STUB_DIR/runquota"
if [ -n "$(exported "$TMP/c3m")" ]; then
  pass "control: without the answer check the stale socket IS exported (case 3 is a real test)"
else
  fail "control: the mutant without the answer check still passed case 3"
fi

# 1. A daemon answers.
: >"$SOCK.alive"
run_step "$SCRIPT" "$TMP/c1" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ "$(exported "$TMP/c1")" = "RUNQUOTA_SOCKET=$SOCK" ] &&
  grep -q '^runquota-endpoint-source=host$' "$TMP/c1/out" && grep -q "^runquota-endpoint=$SOCK\$" "$TMP/c1/out"; then
  pass "a daemon answers: RUNQUOTA_SOCKET exported to the job, source host"
else
  fail "a daemon answers: status=$status env='$(exported "$TMP/c1")' $(cat "$TMP/c1/log")"
fi
grep -q 'setup-dev-env: runquota endpoint: host' "$TMP/c1/log" && [ -s "$TMP/c1/summary" ] &&
  pass "the decision is printed and summarised" || fail "the decision was not printed to the log and summary"

# 4. The client is not available: cannot verify, so nothing is exported.
run_step "$SCRIPT" "$TMP/c4" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" MCL_RUNQUOTA_BIN="$TMP/no-such-client"
if [ "$status" = 0 ] && [ -z "$(exported "$TMP/c4")" ]; then
  pass "no client: an unverifiable socket is not exported, job not failed"
else
  fail "no client: status=$status env='$(exported "$TMP/c4")' $(cat "$TMP/c4/log")"
fi

# 5. A caller's own RUNQUOTA_SOCKET is left alone.
run_step "$SCRIPT" "$TMP/c5" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" RUNQUOTA_SOCKET="$TMP/mine.sock"
if [ "$status" = 0 ] && [ -z "$(exported "$TMP/c5")" ] && grep -q '^runquota-endpoint-source=caller$' "$TMP/c5/out"; then
  pass "a caller's RUNQUOTA_SOCKET is left alone"
else
  fail "caller's socket: status=$status env='$(exported "$TMP/c5")' $(cat "$TMP/c5/log")"
fi

# 6. The input names an endpoint: exported as given, even before it answers.
run_step "$SCRIPT" "$TMP/c6" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" MCL_RUNQUOTA_SOCKET_INPUT="$TMP/chosen.sock"
if [ "$status" = 0 ] && [ "$(exported "$TMP/c6")" = "RUNQUOTA_SOCKET=$TMP/chosen.sock" ] &&
  grep -q '^runquota-endpoint-source=input$' "$TMP/c6/out" && grep -q '::warning::' "$TMP/c6/log"; then
  pass "the runquota-socket input is exported as given, with a warning when nothing answers"
else
  fail "input: status=$status env='$(exported "$TMP/c6")' $(cat "$TMP/c6/log")"
fi

# 6b. A multi-line input would inject a second variable into $GITHUB_ENV: refused.
run_step "$SCRIPT" "$TMP/c6b" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" \
  MCL_RUNQUOTA_SOCKET_INPUT=$'/x.sock\nEVIL=1'
if [ "$status" != 0 ] && [ -z "$(exported "$TMP/c6b")" ] && [ ! -s "$TMP/c6b/out" ]; then
  pass "a multi-line runquota-socket input is refused and writes nothing"
else
  fail "newline input: status=$status env='$(exported "$TMP/c6b")'"
fi

# 7. Windows-style platform: no candidates means nothing to export.
run_step "$SCRIPT" "$TMP/c7" MCL_RUNQUOTA_HOST_SOCKETS= PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ -z "$(exported "$TMP/c7")" ] && grep -q '^runquota-endpoint-source=windows$' "$TMP/c7/out"; then
  pass "no rendezvous candidates (Windows named pipe): nothing to export, job not failed"
else
  fail "no candidates: status=$status $(cat "$TMP/c7/log")"
fi

# Real daemon, when the real binaries are here.
rq_cli="${MCL_TEST_RUNQUOTA_BIN:-$(command -v runquota || true)}"
rq_daemon="${MCL_TEST_RUNQUOTAD_BIN:-$(command -v runquotad || true)}"
if [ -n "$rq_cli" ] && [ -n "$rq_daemon" ] && [ "$(uname -s)" = Linux ]; then
  real="$TMP/real"
  mkdir -m 700 "$real"
  "$rq_daemon" --socket "$real/runquotad.sock" --host-config "$real/host.toml" \
    --host-identity-file "$real/host-id" --estimate-db "$real/est.sqlite" --no-write-stats \
    --ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
    --cpu-milli 2000 --memory-bytes 2147483648 >"$real/daemon.log" 2>&1 &
  daemon_pid="$!"
  for _ in $(seq 1 200); do
    grep -q "runquotad listening" "$real/daemon.log" 2>/dev/null && break
    sleep 0.05
  done
  run_step "$SCRIPT" "$TMP/c8" MCL_RUNQUOTA_HOST_SOCKETS="$real/runquotad.sock" MCL_RUNQUOTA_BIN="$rq_cli"
  if [ "$status" = 0 ] && [ "$(exported "$TMP/c8")" = "RUNQUOTA_SOCKET=$real/runquotad.sock" ]; then
    pass "real runquota client and daemon: the live socket is exported"
  else
    fail "real daemon: status=$status env='$(exported "$TMP/c8")' $(cat "$TMP/c8/log")"
  fi
  # The same socket after the daemon is killed hard: the file stays, nobody answers.
  kill -KILL "$daemon_pid" 2>/dev/null
  wait "$daemon_pid" 2>/dev/null
  daemon_pid=""
  run_step "$SCRIPT" "$TMP/c9" MCL_RUNQUOTA_HOST_SOCKETS="$real/runquotad.sock" MCL_RUNQUOTA_BIN="$rq_cli"
  if [ -S "$real/runquotad.sock" ] && [ "$status" = 0 ] && [ -z "$(exported "$TMP/c9")" ]; then
    pass "real runquota client: the socket a killed daemon left behind is not exported"
  else
    fail "real stale: socket-present=$([ -S "$real/runquotad.sock" ] && echo yes || echo no) status=$status env='$(exported "$TMP/c9")'"
  fi
else
  skip "real runquota/runquotad not available (or not Linux): cases against a real daemon not run"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s), $skips skipped"
  exit 1
fi
echo "all cases passed ($skips skipped)"
