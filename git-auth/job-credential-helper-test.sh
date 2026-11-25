#!/usr/bin/env bash
#
# job-credential-helper-test.sh -- contract suite for the JOB-SCOPED Git
# credential: the `credential.<scope>.helper` that setup-nix's
# configure-git-auth.sh and refresh-build-auth install through `$GITHUB_ENV`
# (scoped_git_auth_emit in ./scoped-git-auth.sh), and the helper it runs,
# ./git-credential-job-token.sh.
#
# WHAT IS UNDER CONTRACT
#   1. 401-then-retry: a private repository is cloned by sending the request
#      without credentials, receiving the server's 401 challenge, calling the
#      helper and retrying -- one Authorization header, never two. A public
#      repository is fetched without the token.
#   2. Scoping by owner path: an owner outside the scopes, or one whose name
#      merely starts with a covered owner's, gets no credential.
#   3. Rotation: a Git process that STARTED before the token file was
#      rotated is handed the rotated token. The server holds the clone's first
#      request until the rotation is done, so the process provably predates it.
#   4. `store` and `erase` leave the token file alone, including the `erase`
#      Git sends after a 401 refuses the helper's credential.
#   5. A missing directory or file answers nothing.
#   6. A header `actions/checkout` persisted into the current checkout is not
#      sent instead of challenging.
#   7. Re-emitting over the job's own configuration (setup-nix run twice,
#      refresh-build-auth) leaves one reset and one helper per scope.
#   8. Broker ownership: while a broker owns `git-token` a writer keeps it; a
#      job that declared `git-access: write` keeps the writer's token.
#   9. A caller's xtrace does not print the token while the file is written.
#
# NO MOCKS. Real git over real HTTP against ./git-http-auth-server.py, which
# serves `git http-backend` and journals per request only a verdict (`none`,
# `ok`, `mismatch`, `public-noauth`, ...), never a credential. The one stand-in
# is the credential broker in (8): an idle process whose argv ends the way the
# real broker's does, because the property under test is the ownership TEST,
# and the real broker needs an App key and GitHub's API
# (refresh-build-auth/job-credentials-test.cjs exercises a real broker
# against a local API). Tokens are constants that authenticate nothing.
#
# Run: bash git-auth/job-credential-helper-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/scoped-git-auth.sh"
HELPER="$HERE/git-credential-job-token.sh"
SERVER="$HERE/git-http-auth-server.py"
CONFIGURE="$HERE/../setup-nix/configure-git-auth.sh"
TEST_PYTHON="${MCL_TEST_PYTHON_EXECUTABLE:-python3}"
for f in "$LIB" "$HELPER" "$SERVER" "$CONFIGURE"; do
  [[ -f $f ]] || {
    echo "job-credential-helper-test: cannot find $f" >&2
    exit 2
  }
done

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "ok   $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL $1"
  [[ -n ${2:-} ]] && echo "     $2"
}
check() { # <desc> <actual> <expected>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

TMPROOT="$(mktemp -d)"
PIDS=()
cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || :; done
  wait 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

TOKEN_A="ghs_TESTONLYjobhelperFirst000000000000000"
TOKEN_B="ghs_TESTONLYjobhelperRotated0000000000000"
TOKEN_WRONG="ghs_TESTONLYjobhelperNotAccepted000000000"
TOKEN_BROKER="ghs_TESTONLYjobhelperBroker00000000000000"

# --- fixtures ---------------------------------------------------------------
SRV="$TMPROOT/srv"
mkdir -p "$SRV/metacraft-labs" "$SRV/outsider" "$SRV/metacraft-labs-evil" "$SRV/public-owner"
SEED="$TMPROOT/seed"
git init -q -b main "$SEED"
printf 'payload\n' >"$SEED/README"
git -C "$SEED" add README
git -C "$SEED" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm seed
for repo in metacraft-labs/private.git outsider/private.git metacraft-labs-evil/private.git public-owner/open.git; do
  git clone -q --bare "$SEED" "$SRV/$repo"
done

# `start_server <name> [server args...]` -- start a server; SERVER_PORT is
# its port.
start_server() {
  local name="$1" port="" tag=""
  shift
  : >"$TMPROOT/$name.counts"
  "$TEST_PYTHON" "$SERVER" --root "$SRV" --journal "$TMPROOT/$name.journal" \
    --header-count-journal "$TMPROOT/$name.counts" "$@" \
    >"$TMPROOT/$name.port" 2>"$TMPROOT/$name.err" &
  PIDS+=("$!")
  for _ in $(seq 1 100); do
    [[ -s $TMPROOT/$name.port ]] && break
    sleep 0.1
  done
  IFS=' ' read -r tag port <"$TMPROOT/$name.port" || :
  [[ $tag == PORT && $port =~ ^[0-9]+$ ]] || {
    echo "job-credential-helper-test: server '$name' did not start" >&2
    cat "$TMPROOT/$name.err" >&2
    exit 2
  }
  SERVER_PORT="$port"
}

printf '%s' "$TOKEN_A" >"$TMPROOT/main.token"
start_server main --auth-file "$TMPROOT/main.token" \
  --auth-prefix=/metacraft-labs/ --auth-prefix=/outsider/ --auth-prefix=/metacraft-labs-evil/
BASE="http://127.0.0.1:${SERVER_PORT}/"

# `verdicts <name> <from-line> <path-substring>` -- the journal verdicts for
# requests to <path-substring> recorded after line <from-line>.
verdicts() {
  local v p
  tail -n +"$(($2 + 1))" "$TMPROOT/$1.journal" | while read -r v p; do
    case "$p" in *"$3"*) printf '%s ' "$v" ;; esac
  done
}
lines() { wc -l <"$1" | tr -d ' '; }
max_headers() { # <name> <from-line>
  tail -n +"$(($2 + 1))" "$TMPROOT/$1.counts" | while read -r n _; do printf '%s\n' "$n"; done |
    sort -n | tail -n 1
}

# `install <case> [env...]` -- run the real configure-git-auth.sh in a fresh
# sandbox, scoped to this server. Sets CASE_ENV (the captured `$GITHUB_ENV`),
# CASE_HOME, CASE_TEMP, CASE_DIR (the credential directory) and CASE_RC.
install() {
  local name="$1"
  shift
  CASE_HOME="$TMPROOT/$name/home"
  CASE_TEMP="$TMPROOT/$name/runner_temp"
  CASE_ENV="$TMPROOT/$name/github_env"
  mkdir -p "$CASE_HOME" "$CASE_TEMP"
  : >"$CASE_ENV"
  CASE_RC=0
  env -i PATH="$PATH" HOME="$CASE_HOME" RUNNER_TEMP="$CASE_TEMP" GITHUB_ENV="$CASE_ENV" \
    GIT_AUTH_URL_BASE="$BASE" GH_TOKEN="$TOKEN_A" "$@" \
    bash "$CONFIGURE" >"$TMPROOT/$name/out" 2>&1 || CASE_RC=$?
  CASE_DIR="$(sed -n 's/^MCL_JOB_CREDENTIALS_DIR=//p' "$CASE_ENV")"
}

# `job_env_args` -- the captured `$GITHUB_ENV`, as `env` arguments: what the
# runner hands every later step.
job_env_args() {
  local line
  JOB_ENV=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] && JOB_ENV+=("$line")
  done <"$CASE_ENV"
}

# `in_job <cwd> <cmd...>` -- run <cmd> as a later step would.
in_job() {
  local cwd="$1"
  shift
  job_env_args
  (cd "$cwd" && env -i PATH="$PATH" HOME="$CASE_HOME" GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CEILING_DIRECTORIES="$TMPROOT" "${JOB_ENV[@]}" "$@")
}

NEUTRAL="$TMPROOT/neutral"
mkdir -p "$NEUTRAL"

# ---------------------------------------------------------------------------
# 1 + 2. 401-then-retry, and scoping by owner path.
# ---------------------------------------------------------------------------
install basic
check "configure-git-auth.sh succeeds" "$CASE_RC" "0"

from="$(lines "$TMPROOT/main.journal")"
cfrom="$(lines "$TMPROOT/main.counts")"
rc=0
in_job "$NEUTRAL" git clone -q "${BASE}metacraft-labs/private.git" "$TMPROOT/basic/clone" >/dev/null 2>&1 || rc=$?
check "a private own-org repository clones" "$rc" "0"
check "...after a 401 challenge, answered by the helper's credential" \
  "$(verdicts main "$from" /metacraft-labs/private.git/info/refs)" "none ok "
check "...with never more than one Authorization header on a request" "$(max_headers main "$cfrom")" "1"

from="$(lines "$TMPROOT/main.journal")"
rc=0
in_job "$NEUTRAL" git clone -q "${BASE}public-owner/open.git" "$TMPROOT/basic/public" >/dev/null 2>&1 || rc=$?
check "a public repository clones" "$rc" "0"
check "...without the token" "$(verdicts main "$from" /public-owner/ | tr ' ' '\n' | sort -u | tr -d '\n')" "public-noauth"

for owner in outsider metacraft-labs-evil; do
  from="$(lines "$TMPROOT/main.journal")"
  rc=0
  in_job "$NEUTRAL" git clone -q "${BASE}${owner}/private.git" "$TMPROOT/basic/$owner" >/dev/null 2>&1 || rc=$?
  check "a private repository of '$owner', outside the scopes, is refused" "$([[ $rc != 0 ]] && echo refused)" "refused"
  check "...because no credential is offered for it, even when challenged" \
    "$(verdicts main "$from" "/$owner/" | tr ' ' '\n' | sort -u | tr -d '\n')" "none"
done

# The same question asked of git's helper selection directly. `useHttpPath` is
# off (git's default, and nothing here sets it), yet the owner path decides.
fill() { # <url> -> the password git's helpers hand over, or nothing
  local line
  printf 'url=%s\n\n' "$1" | in_job "$NEUTRAL" git credential fill 2>/dev/null |
    while IFS= read -r line; do case "$line" in password=*) printf '%s' "${line#password=}" ;; esac; done
}
check "credential.useHttpPath is not set" "$(in_job "$NEUTRAL" git config --get credential.useHttpPath || echo unset)" "unset"
check "git's helpers answer a covered owner's URL" "$(fill "${BASE}metacraft-labs/anything.git")" "$TOKEN_A"
check "git's helpers do not answer another owner's URL" "$(fill "${BASE}outsider/anything.git")" ""
check "git's helpers do not answer an owner that only starts with a covered one" \
  "$(fill "${BASE}metacraft-labs-evil/anything.git")" ""
check "git's helpers do not answer the bare host" "$(fill "$BASE")" ""

# A runner's own helper (Git Credential Manager, `gh auth setup-git`, a
# `~/.git-credentials` store) is configured before the job's and would answer
# first: git stops at the first helper that supplies a password. The scoped
# empty `helper` clears it for the covered URLs, and only for them.
git config --file "$CASE_HOME/.gitconfig" credential.helper \
  '!f() { echo username=runner; echo password=runner-helper-answer; }; f'
check "a runner's own helper does not answer for a covered owner" \
  "$(fill "${BASE}metacraft-labs/anything.git")" "$TOKEN_A"
check "...and still answers for everything else" \
  "$(fill "${BASE}outsider/anything.git")" "runner-helper-answer"
git config --file "$CASE_HOME/.gitconfig" --unset credential.helper

# ---------------------------------------------------------------------------
# 3. Rotation reaches a Git process started before it.
# ---------------------------------------------------------------------------
# A second server that accepts whatever its token file holds NOW, and holds
# the clone's first (unauthenticated) request until told to answer it.
printf '%s' "$TOKEN_A" >"$TMPROOT/rot.token"
start_server rot --auth-file "$TMPROOT/rot.token" --reload-auth-file \
  --hold-file "$TMPROOT/rot.release" --auth-prefix=/metacraft-labs/
ROT_BASE="http://127.0.0.1:${SERVER_PORT}/"
install rotation GIT_AUTH_URL_BASE="$ROT_BASE"
check "configure-git-auth.sh succeeds for the rotation case" "$CASE_RC" "0"
job_env_args
(cd "$NEUTRAL" && env -i PATH="$PATH" HOME="$CASE_HOME" GIT_CONFIG_SYSTEM=/dev/null \
  GIT_CEILING_DIRECTORIES="$TMPROOT" "${JOB_ENV[@]}" \
  git clone -q "${ROT_BASE}metacraft-labs/private.git" "$TMPROOT/rotation/clone" \
  >"$TMPROOT/rotation/clone.out" 2>&1) &
CLONE_PID=$!
# Wait until the clone's request is at the server, so the process is
# demonstrably running, then rotate: the server now accepts only TOKEN_B, and
# the job's token file is replaced by the same writer the broker's peers use.
for _ in $(seq 1 200); do
  [[ -s $TMPROOT/rot.counts ]] && break
  sleep 0.05
done
check "the clone is in flight before the rotation" "$([[ -s $TMPROOT/rot.counts ]] && echo yes)" "yes"
printf '%s' "$TOKEN_B" >"$TMPROOT/rot.token"
# shellcheck source=scoped-git-auth.sh
(. "$LIB" && scoped_git_auth_write_git_token "$CASE_DIR" "$TOKEN_B")
check "the rotation replaced the token file" "$(<"$CASE_DIR/git-token")" "$TOKEN_B"
: >"$TMPROOT/rot.release"
rc=0
wait "$CLONE_PID" || rc=$?
check "the Git process started before the rotation succeeds" "$rc" "0"
check "...with the rotated token" \
  "$(verdicts rot 0 /metacraft-labs/private.git/info/refs)" "none ok "
check "no stray temporary file is left beside the token file" \
  "$(find "$CASE_DIR" -name '.git-token.*' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# 4. store and erase leave the file alone.
# ---------------------------------------------------------------------------
install storeerase
for op in approve reject; do
  printf 'url=%smetacraft-labs/private.git\nusername=x-access-token\npassword=%s\n\n' "$BASE" "$TOKEN_WRONG" |
    in_job "$NEUTRAL" git credential "$op" >/dev/null 2>&1
  check "git credential $op (helper '$([[ $op == approve ]] && echo store || echo erase)') leaves the token file" \
    "$(<"$CASE_DIR/git-token")" "$TOKEN_A"
done
# The real path to `erase`: the server refuses the helper's credential with a
# 401, and Git reports it to its helpers before failing.
printf '%s' "$TOKEN_A" >"$TMPROOT/strict.token"
start_server strict --auth-file "$TMPROOT/strict.token" --mismatch-status 401 --auth-prefix=/metacraft-labs/
STRICT_BASE="http://127.0.0.1:${SERVER_PORT}/"
install refused GIT_AUTH_URL_BASE="$STRICT_BASE" GH_TOKEN="$TOKEN_WRONG"
rc=0
in_job "$NEUTRAL" git clone -q "${STRICT_BASE}metacraft-labs/private.git" \
  "$TMPROOT/refused/clone" >/dev/null 2>&1 || rc=$?
check "a credential the server refuses with 401 fails the clone" "$([[ $rc != 0 ]] && echo failed)" "failed"
check "...after offering it once" "$(verdicts strict 0 /metacraft-labs/private.git/info/refs)" "none mismatch "
check "...and the erase that follows leaves the token file" "$(<"$CASE_DIR/git-token")" "$TOKEN_WRONG"

# ---------------------------------------------------------------------------
# 5. A missing file, or a missing directory, answers nothing.
# ---------------------------------------------------------------------------
install missing
rm -f "$CASE_DIR/git-token"
check "a missing token file answers nothing" "$(fill "${BASE}metacraft-labs/private.git")" ""
rm -rf "$CASE_DIR"
check "a missing credential directory answers nothing" "$(fill "${BASE}metacraft-labs/private.git")" ""
check "the helper itself prints nothing for a missing directory" \
  "$(printf 'protocol=https\nhost=github.com\n\n' | /bin/sh "$HELPER" "$CASE_DIR" get 2>&1)" ""
mkdir -p "$TMPROOT/blank"
printf '\n' >"$TMPROOT/blank/git-token"
check "the helper answers nothing for a blank token file" \
  "$(printf '\n' | /bin/sh "$HELPER" "$TMPROOT/blank" get 2>&1)" ""
printf 'no-newline-token' >"$TMPROOT/blank/git-token"
check "the helper reads a token file without a trailing newline" \
  "$(printf '\n' | /bin/sh "$HELPER" "$TMPROOT/blank" get)" $'username=x-access-token\npassword=no-newline-token'
check "the helper answers nothing for store, and prints nothing" \
  "$(printf 'password=x\n\n' | /bin/sh "$HELPER" "$TMPROOT/blank" store 2>&1)" ""

# ---------------------------------------------------------------------------
# 6. A checkout's persisted header is not sent instead of challenging.
# ---------------------------------------------------------------------------
install checkout
CHECKOUT="$TMPROOT/checkout/consumer"
git init -q "$CHECKOUT"
git -C "$CHECKOUT" config --local "http.${BASE}.extraheader" "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN_WRONG" | base64 | tr -d '\n')"
from="$(lines "$TMPROOT/main.journal")"
cfrom="$(lines "$TMPROOT/main.counts")"
rc=0
in_job "$CHECKOUT" git ls-remote "${BASE}metacraft-labs/private.git" >/dev/null 2>&1 || rc=$?
check "inside a checkout with a persisted catch-all header, an own-org fetch succeeds" "$rc" "0"
check "...challenged first, then the job's credential, never the checkout's" \
  "$(verdicts main "$from" /metacraft-labs/private.git/info/refs)" "none ok "
check "...and never two Authorization headers" "$(max_headers main "$cfrom")" "1"

# ---------------------------------------------------------------------------
# 7. Re-emitting over the job's own configuration does not accumulate.
# ---------------------------------------------------------------------------
install reemit
job_env_args
: >"$TMPROOT/reemit/github_env2"
env -i PATH="$PATH" HOME="$CASE_HOME" RUNNER_TEMP="$CASE_TEMP" GITHUB_ENV="$TMPROOT/reemit/github_env2" \
  GIT_AUTH_URL_BASE="$BASE" GH_TOKEN="$TOKEN_B" "${JOB_ENV[@]}" \
  bash "$CONFIGURE" >"$TMPROOT/reemit/out2" 2>&1
check "a second emit keeps the same credential directory (no new announcement)" \
  "$(grep -c '^MCL_JOB_CREDENTIALS_DIR=' "$TMPROOT/reemit/github_env2")" "0"
check "...and leaves exactly one header reset, one helper reset and one helper" \
  "$(grep '^GIT_CONFIG_KEY_' "$TMPROOT/reemit/github_env2" | sed 's/^GIT_CONFIG_KEY_[0-9]*=//' | tr '\n' ' ')" \
  "http.${BASE}metacraft-labs/.extraHeader credential.${BASE}metacraft-labs/.helper credential.${BASE}metacraft-labs/.helper "
check "...and the second token is what the file now holds" "$(<"$CASE_DIR/git-token")" "$TOKEN_B"

# ---------------------------------------------------------------------------
# 8. Broker ownership of git-token.
# ---------------------------------------------------------------------------
# An idle process whose argv ends like the real broker's.
"$TEST_PYTHON" -c 'import time; time.sleep(600)' /stand-in/job-credentials.cjs daemon &
BROKER_PID=$!
PIDS+=("$BROKER_PID")
broker_case() { # <case> <git-access or ""> <stop:0|1> -> CASE_DIR prepared and installed over
  local name="$1" access="$2" stop="$3" dir
  dir="$TMPROOT/$name/runner_temp/mcl-job-credentials.broker"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf 'access-tokens = github.com=%s\n' "$TOKEN_BROKER" >"$dir/nix-access-tokens.conf"
  printf '%s\n' "$TOKEN_BROKER" >"$dir/git-token"
  printf '%s\n' "$BROKER_PID" >"$dir/broker.pid"
  [[ -n $access ]] && printf '%s\n' "$access" >"$dir/git-access"
  [[ $stop == 1 ]] && : >"$dir/broker.stop"
  install "$name" MCL_JOB_CREDENTIALS_DIR="$dir"
  CASE_DIR="$dir"
}
broker_case broker-read "" 0
check "with a running broker and git-access read, the broker's Git token is kept" "$(<"$CASE_DIR/git-token")" "$TOKEN_BROKER"
check "...and the job is told so, on stderr" \
  "$(grep -c "broker owns this job's Git token" "$TMPROOT/broker-read/out")" "1"
check "...and helpers hand Git the broker's token" "$(fill "${BASE}metacraft-labs/private.git")" "$TOKEN_BROKER"
broker_case broker-write write 0
check "with git-access write, the writer's token replaces it (the broker never owns it)" "$(<"$CASE_DIR/git-token")" "$TOKEN_A"
broker_case broker-stopped "" 1
check "a stopped broker owns nothing" "$(<"$CASE_DIR/git-token")" "$TOKEN_A"
kill "$BROKER_PID" 2>/dev/null
wait "$BROKER_PID" 2>/dev/null
broker_case broker-dead "" 0
check "a dead broker owns nothing" "$(<"$CASE_DIR/git-token")" "$TOKEN_A"

# ---------------------------------------------------------------------------
# 9. A caller's xtrace does not print the token while the file is written.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/xtrace/runner_temp"
: >"$TMPROOT/xtrace/github_env"
rc=0
env -i PATH="$PATH" HOME="$TMPROOT/xtrace" RUNNER_TEMP="$TMPROOT/xtrace/runner_temp" \
  GIT_AUTH_URL_BASE="$BASE" GH_TOKEN="$TOKEN_A" \
  bash -c '. "$1"; scoped_git_auth_build && set -x && scoped_git_auth_emit "$2"; r=$?; case $- in *x*) echo XTRACE-ON ;; esac; set +x; exit "$r"' \
  xtrace-case "$LIB" "$TMPROOT/xtrace/github_env" >"$TMPROOT/xtrace/out" 2>&1 || rc=$?
check "an emit under the caller's xtrace succeeds" "$rc" "0"
check "...and the caller's xtrace is on again afterwards" \
  "$(grep -c "^XTRACE-ON$" "$TMPROOT/xtrace/out")" "1"
check "...and the token file was written" \
  "$(<"$(sed -n 's/^MCL_JOB_CREDENTIALS_DIR=//p' "$TMPROOT/xtrace/github_env")/git-token")" "$TOKEN_A"

# ---------------------------------------------------------------------------
# Nothing printed carries a token.
# ---------------------------------------------------------------------------
leaks=0
for out in "$TMPROOT"/*/out "$TMPROOT"/*/out2 "$TMPROOT"/*.err; do
  [[ -f $out ]] || continue
  for t in "$TOKEN_A" "$TOKEN_B" "$TOKEN_WRONG" "$TOKEN_BROKER"; do
    grep -qF "$t" "$out" && leaks=$((leaks + 1))
  done
done
check "no step output or server log carries a token" "$leaks" "0"
leaks=0
for envf in "$TMPROOT"/*/github_env "$TMPROOT"/*/github_env2; do
  [[ -f $envf ]] || continue
  for t in "$TOKEN_A" "$TOKEN_B" "$TOKEN_WRONG" "$TOKEN_BROKER"; do
    grep -qF "$t" "$envf" && leaks=$((leaks + 1))
  done
done
check "no emitted job environment carries a token" "$leaks" "0"

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "job-credential-helper: CONTRACTS BROKEN." >&2
  exit 1
fi
echo "job-credential-helper: all contracts hold."
