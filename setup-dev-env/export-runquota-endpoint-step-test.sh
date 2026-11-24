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
#  10. the endpoint reports a host id -> ` host_id=<id>` on the endpoint line,
#      `runquota-host-id` output, REPRO_ANNOUNCE_RUNQUOTA_SESSION=1 exported
#  11. no host id (`null`, or an older daemon with no member) -> nothing printed
#  12. an id outside [A-Za-z0-9._-] -> treated as unknown
#  13. no endpoint -> announcement still exported
#  14. Windows named pipe -> the default endpoint's host id is printed
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
# `status --json` prints "$RUNQUOTA_SOCKET.json" when that file exists: the
# daemon's status object as the real client prints it, with or without a
# `host_id`. With no RUNQUOTA_SOCKET (the Windows named pipe) the stub answers
# for MCL_STUB_DEFAULT_ENDPOINT, the endpoint a client uses by default.
cat >"$STUB_DIR/runquota" <<'EOS'
#!/usr/bin/env bash
sock="${RUNQUOTA_SOCKET:-${MCL_STUB_DEFAULT_ENDPOINT:-/nonexistent}}"
[ "${1:-}" = status ] && [ -e "$sock.alive" ] || exit 1
if [ "${2:-}" = --json ] && [ -e "$sock.json" ]; then
  cat "$sock.json"
fi
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
# Only the RUNQUOTA_SOCKET line: the step always exports
# REPRO_ANNOUNCE_RUNQUOTA_SESSION as well, which says nothing about the endpoint.
exported_socket() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in RUNQUOTA_SOCKET=*) printf '%s\n' "$line" ;; esac
  done <"$1/env"
}

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
if [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c2")" ] && grep -q '^runquota-endpoint-source=absent$' "$TMP/c2/out"; then
  pass "no socket: nothing exported, job not failed, source absent"
else
  fail "no socket: status=$status env='$(exported_socket "$TMP/c2")' $(cat "$TMP/c2/log")"
fi

# 3. A socket file nobody answers on.
make_socket_file "$SOCK"
run_step "$SCRIPT" "$TMP/c3" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c3")" ] && grep -q '^runquota-endpoint-source=stale$' "$TMP/c3/out"; then
  pass "stale socket: nothing exported, job not failed, source stale"
else
  fail "stale socket: status=$status env='$(exported_socket "$TMP/c3")' $(cat "$TMP/c3/log")"
fi

# 3m. The control: a script that treats any socket file as an answer exports it.
mutate "$TMP/mutant.sh" '  RUNQUOTA_SOCKET="$1" "$CLI" status >/dev/null 2>&1' '  true'
run_step "$TMP/mutant.sh" "$TMP/c3m" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" MCL_RUNQUOTA_BIN="$STUB_DIR/runquota"
if [ -n "$(exported_socket "$TMP/c3m")" ]; then
  pass "control: without the answer check the stale socket IS exported (case 3 is a real test)"
else
  fail "control: the mutant without the answer check still passed case 3"
fi

# 1. A daemon answers.
: >"$SOCK.alive"
run_step "$SCRIPT" "$TMP/c1" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ "$(exported_socket "$TMP/c1")" = "RUNQUOTA_SOCKET=$SOCK" ] &&
  grep -q '^runquota-endpoint-source=host$' "$TMP/c1/out" && grep -q "^runquota-endpoint=$SOCK\$" "$TMP/c1/out"; then
  pass "a daemon answers: RUNQUOTA_SOCKET exported to the job, source host"
else
  fail "a daemon answers: status=$status env='$(exported_socket "$TMP/c1")' $(cat "$TMP/c1/log")"
fi
grep -q 'setup-dev-env: runquota endpoint: host' "$TMP/c1/log" && [ -s "$TMP/c1/summary" ] &&
  pass "the decision is printed and summarised" || fail "the decision was not printed to the log and summary"

# 4. The client is not available: cannot verify, so nothing is exported.
run_step "$SCRIPT" "$TMP/c4" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" MCL_RUNQUOTA_BIN="$TMP/no-such-client"
if [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c4")" ]; then
  pass "no client: an unverifiable socket is not exported, job not failed"
else
  fail "no client: status=$status env='$(exported_socket "$TMP/c4")' $(cat "$TMP/c4/log")"
fi

# 5. A caller's own RUNQUOTA_SOCKET is left alone.
run_step "$SCRIPT" "$TMP/c5" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" RUNQUOTA_SOCKET="$TMP/mine.sock"
if [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c5")" ] && grep -q '^runquota-endpoint-source=caller$' "$TMP/c5/out"; then
  pass "a caller's RUNQUOTA_SOCKET is left alone"
else
  fail "caller's socket: status=$status env='$(exported_socket "$TMP/c5")' $(cat "$TMP/c5/log")"
fi

# 6. The input names an endpoint: exported as given, even before it answers.
run_step "$SCRIPT" "$TMP/c6" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" MCL_RUNQUOTA_SOCKET_INPUT="$TMP/chosen.sock"
if [ "$status" = 0 ] && [ "$(exported_socket "$TMP/c6")" = "RUNQUOTA_SOCKET=$TMP/chosen.sock" ] &&
  grep -q '^runquota-endpoint-source=input$' "$TMP/c6/out" && grep -q '::warning::' "$TMP/c6/log"; then
  pass "the runquota-socket input is exported as given, with a warning when nothing answers"
else
  fail "input: status=$status env='$(exported_socket "$TMP/c6")' $(cat "$TMP/c6/log")"
fi

# 6b. A multi-line input would inject a second variable into $GITHUB_ENV: refused.
run_step "$SCRIPT" "$TMP/c6b" MCL_RUNQUOTA_HOST_SOCKETS="$SOCK" PATH="$STUB_DIR:$PATH" \
  MCL_RUNQUOTA_SOCKET_INPUT=$'/x.sock\nEVIL=1'
if [ "$status" != 0 ] && [ -z "$(exported_socket "$TMP/c6b")" ] && [ ! -s "$TMP/c6b/out" ]; then
  pass "a multi-line runquota-socket input is refused and writes nothing"
else
  fail "newline input: status=$status env='$(exported_socket "$TMP/c6b")'"
fi

# 7. Windows-style platform: no candidates means nothing to export.
run_step "$SCRIPT" "$TMP/c7" MCL_RUNQUOTA_HOST_SOCKETS= PATH="$STUB_DIR:$PATH"
if [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c7")" ] && grep -q '^runquota-endpoint-source=windows$' "$TMP/c7/out"; then
  pass "no rendezvous candidates (Windows named pipe): nothing to export, job not failed"
else
  fail "no candidates: status=$status $(cat "$TMP/c7/log")"
fi

# 10. The endpoint names its host: `host_id=<id>` on the endpoint line and the
#     `runquota-host-id` output, and REPRO_ANNOUNCE_RUNQUOTA_SESSION=1 for the
#     later steps, so a job record joins the observation rows by host and
#     session. The stub prints the daemon's status object as the real client
#     does: its members at the top level, `enforcement` and `measurement`
#     beside them.
HID_SOCK="$sockdir/hid.sock"
make_socket_file "$HID_SOCK"
: >"$HID_SOCK.alive"
status_json() { # status_json <host_id member text>
  printf '{"active_sessions":0,"active_leases":0,"total_granted":3,"total_finished":3,%s"total_rejected":0,"capacity":{"cpu_budget_milli":4000},"enforcement":{"os":"linux"},"measurement":{"os":"linux"}}\n' "$1"
}
endpoint_line() { # the one endpoint line of a case's log
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "setup-dev-env: runquota endpoint: "*) printf '%s\n' "$line" ;; esac
  done <"$1/log"
}
has_line() { # has_line <file> <exact line>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$2" ] && return 0
  done <"$1"
  return 1
}

status_json '"host_id":"rqh-01HZX9.a_b-c",' >"$HID_SOCK.json"
run_step "$SCRIPT" "$TMP/c10" MCL_RUNQUOTA_HOST_SOCKETS="$HID_SOCK" PATH="$STUB_DIR:$PATH"
c10_line="$(endpoint_line "$TMP/c10")"
case "$c10_line" in
"setup-dev-env: runquota endpoint: host: "*" host_id=rqh-01HZX9.a_b-c") c10_ok=1 ;;
*) c10_ok=0 ;;
esac
if [ "$status" = 0 ] && [ "$c10_ok" = 1 ] &&
  has_line "$TMP/c10/out" "runquota-host-id=rqh-01HZX9.a_b-c" &&
  has_line "$TMP/c10/env" "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1" &&
  has_line "$TMP/c10/env" "RUNQUOTA_SOCKET=$HID_SOCK"; then
  pass "a daemon with a host id: host_id= on the endpoint line, runquota-host-id output, session announcement exported"
else
  fail "host id: status=$status line='$c10_line' out='$(cat "$TMP/c10/out")' env='$(exported "$TMP/c10")'"
fi

# 11. A daemon without one (capture off answers `null`; an older daemon has no
#     member at all): nothing printed for it, an empty output, and the session
#     announcement still exported.
for variant in null missing; do
  case "$variant" in
  null) status_json '"host_id":null,' >"$HID_SOCK.json" ;;
  missing) status_json '' >"$HID_SOCK.json" ;;
  esac
  run_step "$SCRIPT" "$TMP/c11$variant" MCL_RUNQUOTA_HOST_SOCKETS="$HID_SOCK" PATH="$STUB_DIR:$PATH"
  line="$(endpoint_line "$TMP/c11$variant")"
  case "$line" in *host_id=*) printed=1 ;; *) printed=0 ;; esac
  if [ "$status" = 0 ] && [ "$printed" = 0 ] && [ -n "$line" ] &&
    has_line "$TMP/c11$variant/out" "runquota-host-id=" &&
    has_line "$TMP/c11$variant/env" "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1"; then
    pass "a daemon with no host id ($variant): nothing printed, empty output, announcement exported"
  else
    fail "no host id ($variant): status=$status line='$line' out='$(cat "$TMP/c11$variant/out")' env='$(exported "$TMP/c11$variant")'"
  fi
done

# 12. An id outside [A-Za-z0-9._-] is treated as unknown: the endpoint line and
#     the output are parsed downstream, so a space, a quote escape or a shell
#     metacharacter must not reach them.
for unsafe in 'rqh-a b' 'rqh-a\"b' 'rqh-$(id)' 'rqh-a;b' ''; do
  status_json "\"host_id\":\"$unsafe\"," >"$HID_SOCK.json"
  run_step "$SCRIPT" "$TMP/c12" MCL_RUNQUOTA_HOST_SOCKETS="$HID_SOCK" PATH="$STUB_DIR:$PATH"
  line="$(endpoint_line "$TMP/c12")"
  case "$line" in *host_id=*) printed=1 ;; *) printed=0 ;; esac
  if [ "$status" = 0 ] && [ "$printed" = 0 ] && has_line "$TMP/c12/out" "runquota-host-id=" &&
    has_line "$TMP/c12/env" "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1"; then
    pass "an unsafe host id ('$unsafe') is treated as unknown"
  else
    fail "unsafe host id ('$unsafe'): status=$status line='$line' out='$(cat "$TMP/c12/out")'"
  fi
done

# 12m. The control: without the character check, the unsafe id reaches the line.
mutate "$TMP/mutant-id.sh" '  "" | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 0 ;;' '  "") return 0 ;;'
status_json '"host_id":"rqh-a;b",' >"$HID_SOCK.json"
run_step "$TMP/mutant-id.sh" "$TMP/c12m" MCL_RUNQUOTA_HOST_SOCKETS="$HID_SOCK" PATH="$STUB_DIR:$PATH"
case "$(endpoint_line "$TMP/c12m")" in
*" host_id=rqh-a;b") pass "control: without the character check the unsafe id IS printed (case 12 is a real test)" ;;
*) fail "control: the mutant without the character check still passed case 12" ;;
esac

# 13. No endpoint at all: no host id, and the announcement is exported anyway
#     (repro then registers with the user's shared daemon, whose sessions are
#     joined the same way).
if has_line "$TMP/c2/env" "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1" && has_line "$TMP/c2/out" "runquota-host-id="; then
  pass "no endpoint: announcement exported, empty runquota-host-id"
else
  fail "no endpoint: out='$(cat "$TMP/c2/out")' env='$(exported "$TMP/c2")'"
fi

# 14. The Windows named pipe: the endpoint is the client's default, so the host
#     id is asked of it with no RUNQUOTA_SOCKET.
status_json '"host_id":"rqh-win",' >"$HID_SOCK.json"
run_step "$SCRIPT" "$TMP/c14" MCL_RUNQUOTA_HOST_SOCKETS= PATH="$STUB_DIR:$PATH" MCL_STUB_DEFAULT_ENDPOINT="$HID_SOCK"
c14_line="$(endpoint_line "$TMP/c14")"
case "$c14_line" in *" host_id=rqh-win") c14_ok=1 ;; *) c14_ok=0 ;; esac
if [ "$status" = 0 ] && [ "$c14_ok" = 1 ] && has_line "$TMP/c14/out" "runquota-host-id=rqh-win" &&
  [ -z "$(exported_socket "$TMP/c14")" ]; then
  pass "Windows named pipe: the default endpoint's host id is printed, nothing exported as the socket"
else
  fail "windows host id: status=$status line='$c14_line' out='$(cat "$TMP/c14/out")'"
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
  if [ "$status" = 0 ] && [ "$(exported_socket "$TMP/c8")" = "RUNQUOTA_SOCKET=$real/runquotad.sock" ]; then
    pass "real runquota client and daemon: the live socket is exported"
    c8_line="$(endpoint_line "$TMP/c8")"
    case "$c8_line" in *host_id=*) c8_printed=1 ;; *) c8_printed=0 ;; esac
    if [ "$c8_printed" = 0 ] && has_line "$TMP/c8/out" "runquota-host-id=" &&
      has_line "$TMP/c8/env" "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1"; then
      pass "real daemon with capture off: no host_id printed, announcement exported"
    else
      fail "real daemon host id: line='$c8_line' out='$(cat "$TMP/c8/out")'"
    fi
  else
    fail "real daemon: status=$status env='$(exported_socket "$TMP/c8")' $(cat "$TMP/c8/log")"
  fi
  # The same socket after the daemon is killed hard: the file stays, nobody answers.
  kill -KILL "$daemon_pid" 2>/dev/null
  wait "$daemon_pid" 2>/dev/null
  daemon_pid=""
  run_step "$SCRIPT" "$TMP/c9" MCL_RUNQUOTA_HOST_SOCKETS="$real/runquotad.sock" MCL_RUNQUOTA_BIN="$rq_cli"
  if [ -S "$real/runquotad.sock" ] && [ "$status" = 0 ] && [ -z "$(exported_socket "$TMP/c9")" ]; then
    pass "real runquota client: the socket a killed daemon left behind is not exported"
  else
    fail "real stale: socket-present=$([ -S "$real/runquotad.sock" ] && echo yes || echo no) status=$status env='$(exported_socket "$TMP/c9")'"
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
