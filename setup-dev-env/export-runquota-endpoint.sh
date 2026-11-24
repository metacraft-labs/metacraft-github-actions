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
# HOST IDENTITY. A CI job record is joined to RunQuota's observation rows by the
# host id and the session id (reprobuild-pm spec/Build-Engine-And-Scheduler.md,
# "Naming the host and the session in a CI job log"). When the endpoint chosen
# (caller, input, host, or the Windows default pipe) answers
# `runquota status --json` with a `host_id`, the endpoint line ends in
# ` host_id=<id>` and the id is written to the `runquota-host-id` output. An
# unknown id prints nothing, and an id with any character outside
# [A-Za-z0-9._-] is treated as unknown, because the line and the output are
# parsed downstream. The step also exports REPRO_ANNOUNCE_RUNQUOTA_SESSION=1 on
# every path, so `repro` prints `runquota: session_id=<id>` on stderr for each
# RunQuota session it registers in the later steps.
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
# Outputs: `runquota-endpoint`, `runquota-endpoint-source` (the DECISION) and
# `runquota-host-id` (empty when unknown) to $GITHUB_OUTPUT, RUNQUOTA_SOCKET to
# $GITHUB_ENV when exported, REPRO_ANNOUNCE_RUNQUOTA_SESSION=1 to $GITHUB_ENV
# always, and one line to the log and $GITHUB_STEP_SUMMARY on every path.
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

# host_id_of [SOCKET]: print the `host_id` the daemon reports, or nothing when
# it reports none (`null`, an older daemon with no such member, no answer) or
# one that is not a safe token. Empty SOCKET asks the client's default endpoint
# (the Windows named pipe).
#
# `runquota status --json` prints one JSON object whose members are the
# daemon's, with `host_id` the first member after the wire counters, so the
# first `"host_id":` in the text is the daemon's own. Parsed with parameter
# expansion only (no awk/sed/grep, no jq on a stock runner).
host_id_of() {
  [ -n "$CLI" ] && [ -x "$CLI" ] || return 0
  local json rest id
  if [ -n "$1" ]; then
    json="$(RUNQUOTA_SOCKET="$1" "$CLI" status --json 2>/dev/null)" || return 0
  else
    # Only on the `windows` path, where RUNQUOTA_SOCKET is not set (it would
    # have been the `caller` decision).
    json="$("$CLI" status --json 2>/dev/null)" || return 0
  fi
  rest="${json#*\"host_id\":}"
  [ "$rest" != "$json" ] || return 0
  # Tolerate whitespace after the colon, from a pretty-printing client.
  rest="${rest#"${rest%%[! ]*}"}"
  case "$rest" in
  \"*) rest="${rest#\"}" ;;
  *) return 0 ;; # null, or not a string
  esac
  case "$rest" in
  *\"*) id="${rest%%\"*}" ;;
  *) return 0 ;; # unterminated
  esac
  # An escaped quote (\") leaves a backslash in `id`, which the set refuses.
  # The set is spelled out rather than as ranges, whose meaning depends on
  # the locale.
  case "$id" in
  "" | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 0 ;;
  esac
  [ "${#id}" -le 128 ] || return 0
  printf '%s' "$id"
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

HOST_ID=""
case "$DECISION" in
caller | input | host) HOST_ID="$(host_id_of "$ENDPOINT")" ;;
windows) HOST_ID="$(host_id_of "")" ;;
esac
HOST_ID_SUFFIX=""
if [ -n "$HOST_ID" ]; then
  HOST_ID_SUFFIX=" host_id=${HOST_ID}"
fi

echo "setup-dev-env: runquota endpoint: ${DECISION}: ${REASON}${HOST_ID_SUFFIX}"
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
if [ -n "${GITHUB_ENV:-}" ]; then
  # Every path: with no host daemon `repro` registers with the user's shared
  # daemon, and its session ids are joined the same way.
  echo "REPRO_ANNOUNCE_RUNQUOTA_SESSION=1" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "runquota-endpoint=${EXPORTED}"
    echo "runquota-endpoint-source=${DECISION}"
    echo "runquota-host-id=${HOST_ID}"
  } >>"$GITHUB_OUTPUT"
fi
exit 0
