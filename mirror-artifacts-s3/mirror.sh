#!/usr/bin/env bash
#
# mirror.sh — the body of the `mirror-artifacts-s3` composite step.
#
# Copies MCL_S3_PATH to the in-house S3 store and NEVER exits non-zero: every
# outcome other than a completed upload is a `::warning` and exit 0, so the
# job's result stays whatever its real steps made it.
#
# WHY THE UPLOAD IS TIME-BOUNDED
# ------------------------------
# "Never fails" is not enough for a non-blocking step: one that never ENDS
# blocks the job just as well. Recorder CI jobs sat in this step for 1-3 hours
# (an upload of a whole `target/` or `.repro/` tree, from runners whose path to
# the store is a VPN) until someone cancelled the run by hand, holding a scarce
# macOS or bare-metal runner the whole time. A composite step cannot take
# `timeout-minutes`, so the bound has to live here.
#
# The bound is enforced in bash rather than with coreutils `timeout`, because
# the action runs on Linux, macOS (BSD userland; `timeout` is only there when
# GNU coreutils happens to be on PATH) and Windows Git Bash. The client is
# started in its own process group (`set -m`), so on expiry the whole tree is
# signalled — including the real `aws` that `nix shell … -c aws` starts under
# it. A survivor that holds the step's stdout open would keep the step open
# even after this script exits, which is exactly how the orphaned
# `.aws-wrapped` processes showed up.
#
# Inputs (environment, set by action.yml):
#   MCL_S3_PATH, MCL_S3_PREFIX, MCL_S3_ENDPOINT, MCL_S3_BUCKET, MCL_S3_REGION
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  (absent => repo not onboarded)
#   MCL_S3_TIMEOUT_MINUTES      wall-clock bound on the upload (default 10)
# Test hooks (not action inputs; the contract suite needs a sub-minute bound):
#   MCL_S3_TIMEOUT_SECONDS      overrides MCL_S3_TIMEOUT_MINUTES when set
#   MCL_S3_KILL_GRACE_SECONDS   SIGTERM -> SIGKILL grace (default 10)
# action.yml sets both to "" so a job-level `env:` cannot reach them.
#
# Written for bash 3.2 (stock macOS): no `wait -n`, no associative arrays,
# and empty arrays are expanded with the `${a[@]+"${a[@]}"}` idiom.
set -u

warn() { echo "::warning title=S3 artifact mirror::$*"; }

# Onboarding guard: a repo without the credential is simply not onboarded.
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${MCL_S3_ENDPOINT:-}" ]]; then
  echo "In-house S3 artifact store not configured for this repo; skipping mirror."
  exit 0
fi
# Nothing to upload is not an error.
if [[ ! -e "${MCL_S3_PATH:-}" ]]; then
  echo "Path '${MCL_S3_PATH:-}' does not exist; nothing to mirror."
  exit 0
fi

# Resolve the bound. A malformed value must not turn into "no bound" (or into
# a shell arithmetic error that skips the bound), so it falls back to the
# default with a warning.
timeout_min="${MCL_S3_TIMEOUT_MINUTES:-10}"
if ! [[ "$timeout_min" =~ ^[0-9]+$ ]] || (( 10#$timeout_min == 0 )); then
  warn "timeout-minutes '${timeout_min}' is not a positive integer; using 10"
  timeout_min=10
fi
limit_s=$(( 10#$timeout_min * 60 ))
if [[ "${MCL_S3_TIMEOUT_SECONDS:-}" =~ ^[0-9]+$ ]] && (( 10#$MCL_S3_TIMEOUT_SECONDS > 0 )); then
  limit_s=$(( 10#$MCL_S3_TIMEOUT_SECONDS ))
fi
grace_s=10
if [[ "${MCL_S3_KILL_GRACE_SECONDS:-}" =~ ^[0-9]+$ ]]; then
  grace_s=$(( 10#$MCL_S3_KILL_GRACE_SECONDS ))
fi

# Resolve an S3 client: prefer one on PATH, else borrow awscli2 from nix.
if command -v aws >/dev/null 2>&1; then
  aws_cmd=(aws)
elif command -v nix >/dev/null 2>&1; then
  aws_cmd=(nix shell nixpkgs#awscli2 -c aws)
else
  warn "no aws/nix on this runner; skipping mirror (GitHub artifact retained)"
  exit 0
fi

# Reachability: the store is routable only over the NetBird VPN, so a
# GitHub-hosted runner cannot open a connection to it. Without this probe the
# client attempted every file anyway, each attempt ending in
# AWS_IO_SOCKET_TIMEOUT after its retries: one io-mon run logged ~3000 failed
# and 0 completed uploads per job, and the step held each job until the
# caller's timeout cancelled it. Any HTTP answer (an unauthenticated S3
# endpoint answers 403) proves the endpoint is reachable, and curl exits 0 for
# it without `--fail`; only a failure to connect or to get an answer at all
# skips. An upload error on a reachable store is still reported below as one.
# Without curl, fall through to the upload.
if command -v curl >/dev/null 2>&1; then
  if ! curl -sS -o /dev/null --connect-timeout 10 --max-time 30 "$MCL_S3_ENDPOINT" </dev/null; then
    warn "endpoint $MCL_S3_ENDPOINT is unreachable from this runner (not on the NetBird VPN?); skipping mirror (GitHub artifact retained)"
    exit 0
  fi
fi

prefix="${MCL_S3_PREFIX:-}"
if [[ -z "$prefix" ]]; then
  prefix="$(basename "$MCL_S3_PATH")/${GITHUB_RUN_ID:-manual}"
fi
dest="s3://${MCL_S3_BUCKET:-ci-artifacts}/${prefix%/}/"
cp_args=()
[[ -d "$MCL_S3_PATH" ]] && cp_args=(--recursive)

# Signal the client's whole process group; fall back to the pid alone if the
# group is already gone. On Windows Git Bash a native aws.exe is not part of
# the MSYS process group and cannot handle a POSIX signal gracefully, so ask
# Windows to end its process tree first, while the MSYS pid still maps to it
# (/proc/<pid>/winpid exists only under MSYS/Cygwin, and vanishes once the
# first signal has ended the process).
client_pid=""
signal_client() {
  local sig="$1"
  [[ -n "$client_pid" ]] || return 0
  if [[ -r "/proc/$client_pid/winpid" ]] && command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$(cat "/proc/$client_pid/winpid")" >/dev/null 2>&1
  fi
  kill -s "$sig" -- "-$client_pid" 2>/dev/null || kill -s "$sig" "$client_pid" 2>/dev/null
  return 0
}

# TERM, then KILL after the grace period if anything in the group survives.
stop_client() {
  local waited=0
  signal_client TERM
  while kill -0 "$client_pid" 2>/dev/null && (( waited < grace_s )); do
    sleep 1
    waited=$(( waited + 1 ))
  done
  # The group may outlive its leader (a grandchild that ignored TERM), so
  # KILL unconditionally rather than only when the leader is still alive.
  signal_client KILL
  wait "$client_pid" 2>/dev/null
}

# If the runner cancels the step, it signals this script, not the client's
# separate process group; pass the cancellation on instead of orphaning it.
trap 'stop_client; exit 0' INT TERM

# Fail fast on a dead or stalled endpoint instead of riding the client's
# retries: the CLI's own defaults are 60 s for both. The connect timeout is
# shortened to 20 s; the read timeout states the default so it cannot drift.
# Neither caps the step: a slow upload that keeps making progress never trips
# them, which is why the wall-clock bound below exists.
set -m
"${aws_cmd[@]}" --endpoint-url "$MCL_S3_ENDPOINT" --region "${MCL_S3_REGION:-garage}" \
  --cli-connect-timeout 20 --cli-read-timeout 60 \
  s3 cp ${cp_args[@]+"${cp_args[@]}"} "$MCL_S3_PATH" "$dest" </dev/null &
client_pid=$!
set +m

# Poll rather than `wait`, so the deadline is checked while the client runs.
started=$SECONDS
timed_out=0
while kill -0 "$client_pid" 2>/dev/null; do
  if (( SECONDS - started >= limit_s )); then
    timed_out=1
    break
  fi
  sleep 1
done

if (( timed_out )); then
  stop_client
  trap - INT TERM
  warn "upload did not finish within ${limit_s}s and was stopped (non-blocking); the S3 copy may be partial, GitHub artifact retained"
  exit 0
fi

wait "$client_pid"
rc=$?
# The client has exited, but a process it started may not have (a crashed
# wrapper whose real client is still running). Anything left in the group is
# outside every bound and would hold the step's stdout open, so end it. Only
# the group is signalled here, never the reaped pid, which may be reused.
kill -s KILL -- "-$client_pid" 2>/dev/null
trap - INT TERM
if (( rc == 0 )); then
  echo "Mirrored '$MCL_S3_PATH' to $dest"
else
  warn "upload failed with exit ${rc} (non-blocking); GitHub artifact retained"
fi
exit 0
