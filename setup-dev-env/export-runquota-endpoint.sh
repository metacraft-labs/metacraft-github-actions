#!/usr/bin/env bash
#
# export-runquota-endpoint.sh — make the steps after setup-dev-env draw on the
# HOST's RunQuota daemon.
#
# RunQuota admits builds against one budget per machine. That only works if
# every build on the machine talks to the same daemon: a job step that starts a
# private daemon of its own (a build script, a test runner) gives itself a whole
# budget, and two concurrent jobs together overrun the runner. `repro` finds the
# host's daemon by itself, but a script that calls the `runquota` client, or
# starts a daemon when it finds none, needs to be told where it is. This step
# tells the rest of the job: when a daemon answers on the host's rendezvous, it
# exports RUNQUOTA_SOCKET for the later steps.
#
# DECISION is one of:
#   caller   — RUNQUOTA_SOCKET was already set; untouched.
#   input    — the `runquota-socket` input names an endpoint; exported as given
#              (an operator's explicit choice), with a warning when nothing
#              answers there.
#   host     — a daemon answers on the host rendezvous socket; exported.
#   windows  — nothing to export: the host's endpoint is a fixed named pipe,
#              which every client uses by default.
#   absent   — no host daemon found. Nothing is exported and the job does NOT
#              fail: `repro` then adopts, or starts, the invoking user's shared
#              per-user daemon on its own, which is the supported fallback on
#              a runner with no RunQuota service. Not an error, and not
#              silent: the decision is always printed.
#   stale    — a socket is there but nothing answers (or the `runquota` client
#              needed to ask is not on PATH). Nothing is exported, for the same
#              reason: pointing every later step at an endpoint that does not
#              answer would turn a working fallback into a failure.
#
# "Answers" means `runquota status` succeeds on that socket. A socket file alone
# is not an answer: it outlives a daemon that was killed.
#
# PORTABILITY. bash 3.2 (GitHub's macOS images) and Git Bash on Windows; no
# awk/sed/grep.
#
# INPUTS arrive as environment variables set by the action's `env:` block:
#   MCL_RUNQUOTA_SOCKET_INPUT   the `runquota-socket` input (may be empty)
#   MCL_RUNQUOTA_HOST_SOCKETS   space-separated rendezvous sockets to try;
#                               default /run/runquota/runquotad.sock (Linux) or
#                               /var/run/runquota/runquotad.sock (macOS). Set by
#                               the contract suite, which must not use /run.
#   MCL_RUNQUOTA_BIN            the `runquota` client; default the one on PATH.
# Outputs: `runquota-endpoint` and `runquota-endpoint-source` (the DECISION) to
# $GITHUB_OUTPUT, RUNQUOTA_SOCKET to $GITHUB_ENV when exported, and one line to
# the log and $GITHUB_STEP_SUMMARY on every path.
set -euo pipefail

INPUT="${MCL_RUNQUOTA_SOCKET_INPUT-}"
# The input is written into $GITHUB_ENV and $GITHUB_OUTPUT as `NAME=value`
# lines. A newline (or CR) in it would start a second line there, i.e. let the
# value inject another variable into every later step. Refuse it outright.
case "$INPUT" in
*$'\n'* | *$'\r'*)
  echo "::error::setup-dev-env: runquota-socket must be a single line" >&2
  exit 1
  ;;
esac
case "$(uname -s)" in
Darwin) DEFAULT_SOCKETS="/var/run/runquota/runquotad.sock" ;;
MINGW* | MSYS* | CYGWIN* | Windows_NT) DEFAULT_SOCKETS="" ;;
*) DEFAULT_SOCKETS="/run/runquota/runquotad.sock" ;;
esac
CANDIDATES="${MCL_RUNQUOTA_HOST_SOCKETS-$DEFAULT_SOCKETS}"
CLI="${MCL_RUNQUOTA_BIN:-}"
if [ -z "$CLI" ]; then
  CLI="$(command -v runquota 2>/dev/null || true)"
fi

# answers SOCKET: does a daemon answer `status` there?
answers() {
  [ -n "$CLI" ] && [ -x "$CLI" ] || return 1
  RUNQUOTA_SOCKET="$1" "$CLI" status >/dev/null 2>&1
}

DECISION=""
ENDPOINT=""
REASON=""

if [ -n "${RUNQUOTA_SOCKET:-}" ]; then
  DECISION="caller"
  ENDPOINT="$RUNQUOTA_SOCKET"
  REASON="RUNQUOTA_SOCKET was already set to ${RUNQUOTA_SOCKET} before this action ran; leaving it alone"
elif [ -n "$INPUT" ]; then
  DECISION="input"
  ENDPOINT="$INPUT"
  if answers "$INPUT"; then
    REASON="runquota-socket names ${INPUT}, and a daemon answers there"
  else
    REASON="runquota-socket names ${INPUT}; nothing answers there yet (or the runquota client is not on PATH), exporting it as given"
    echo "::warning::setup-dev-env: runquota-socket ${INPUT} did not answer a status request" >&2
  fi
elif [ -z "$CANDIDATES" ]; then
  DECISION="windows"
  REASON="the host's RunQuota endpoint on this platform is a fixed named pipe that clients use by default; nothing to export"
else
  DECISION="absent"
  REASON="no RunQuota service socket at: ${CANDIDATES}; repro will adopt or start the user's shared daemon"
  for sock in $CANDIDATES; do
    [ -S "$sock" ] || continue
    if answers "$sock"; then
      DECISION="host"
      ENDPOINT="$sock"
      REASON="the host's RunQuota daemon answers on ${sock}"
      break
    fi
    DECISION="stale"
    REASON="${sock} exists but no daemon answers there (or the runquota client is not on PATH); not exporting it"
  done
fi

echo "setup-dev-env: runquota endpoint: ${DECISION}: ${REASON}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- RunQuota endpoint: \`${DECISION}\` — ${REASON}" >>"$GITHUB_STEP_SUMMARY"
fi

EXPORTED=""
case "$DECISION" in
input | host) EXPORTED="$ENDPOINT" ;;
esac
if [ -n "$EXPORTED" ] && [ -n "${GITHUB_ENV:-}" ]; then
  echo "RUNQUOTA_SOCKET=${EXPORTED}" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "runquota-endpoint=${EXPORTED}"
    echo "runquota-endpoint-source=${DECISION}"
  } >>"$GITHUB_OUTPUT"
fi
exit 0
