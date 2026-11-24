#!/usr/bin/env bash
#
# enable-nix-features-step-test.sh — contract suite for enable-nix-features.sh
# and its wiring in setup-dev-env/action.yml.
#
# WHAT IS BEING GUARDED
# ---------------------
# On a runner whose `nix` was already on PATH, setup-dev-env configured
# nothing, and the job's Nix ran with its defaults: the first `repro exec`
# died in `nix print-dev-env` with "experimental Nix feature 'nix-command' is
# disabled" (codetracer-shell-recorders job 138310567518, 2026-11-24). The
# script appends `extra-experimental-features = nix-command flakes` to the
# job's NIX_CONFIG, keeping everything already there.
#
# The cases run the REAL `nix` on PATH, made unconfigured: NIX_CONF_DIR is an
# empty directory and NIX_USER_CONF_FILES an empty file, so neither the host's
# /etc/nix/nix.conf nor a user nix.conf can enable a feature. `nix config show`
# itself needs `nix-command`, so it fails exactly as the job did until the
# feature is on. A stub `nix` could only test the stub.
#
#   0. Fixture: the job's NIX_CONFIG (an `!include` of the credential file)
#      leaves the new CLI disabled -- the defect reproduces here.
#   1. After the script: the new CLI runs, both features are on, and the
#      `!include` is kept, first.
#   2. Through the Nix authentication step that follows it in action.yml
#      (refresh-build-auth/nix-auth.cjs refreshNix): the line survives.
#   3. Additive: a NIX_CONFIG that sets `experimental-features` keeps it.
#   4. Idempotent: a second run leaves $GITHUB_ENV untouched.
#   5. A credential in NIX_CONFIG is kept verbatim and never printed.
#   6. Without $GITHUB_ENV the script fails instead of exporting nothing.
#   7. Wiring: the step runs for the reprobuild flavor off Windows, after the
#      Nix install decision and install, and before the first step that runs
#      `nix` or `repro`.
# NEGATIVE CONTROL: case 1 is repeated against a MUTANT of the script that
# does not append the setting, and must fail there. `mutate` aborts when the
# line it replaces is not there, so the control cannot silently stop mutating.
#
# Needs: `nix` (2.20+, for `nix config show`) and, for case 2, Node -- the
# runtime the action binds (GHA_NIX_AUTH_NODE), else `node` on PATH. Either
# missing is a failure, not a skip. No network.
# Run:  bash setup-dev-env/enable-nix-features-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/enable-nix-features.sh"
ACTION="${HERE}/action.yml"
NIX_AUTH="${HERE}/../refresh-build-auth/nix-auth.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

NIX_BIN="$(command -v nix || true)"
NODE_BIN="${GHA_NIX_AUTH_NODE:-$(command -v node || true)}"
if [ -z "$NIX_BIN" ]; then
  echo "FAIL this suite needs a real nix on PATH" >&2
  exit 1
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "FAIL this suite needs Node (GHA_NIX_AUTH_NODE or node on PATH)" >&2
  exit 1
fi

# The unconfigured-Nix fixture.
mkdir -p "$TMP/etc"
: >"$TMP/empty.conf"
TOKENS="$TMP/nix-access-tokens.conf"
printf 'access-tokens = github.com=old-fixture-not-a-credential\n' >"$TOKENS"
chmod 600 "$TOKENS"
INCLUDE="!include $TOKENS"
SETTING="extra-experimental-features = nix-command flakes"

# nix_with CONFIG ARGS...: run the real nix, unconfigured apart from CONFIG.
nix_with() {
  local config="$1"
  shift
  env NIX_CONF_DIR="$TMP/etc" NIX_USER_CONF_FILES="$TMP/empty.conf" \
    XDG_CONFIG_HOME="$TMP/xdg" XDG_CONFIG_DIRS="$TMP/etc" \
    NIX_CONFIG="$config" "$NIX_BIN" "$@"
}

# run_script SCRIPT DIR CONFIG|-: run in a clean environment (CONFIG `-` leaves
# NIX_CONFIG unset); leaves $status, DIR/env (the $GITHUB_ENV file) and DIR/log.
run_script() {
  local script="$1" dir="$2" config="$3"
  mkdir -p "$dir"
  [ -f "$dir/env" ] || : >"$dir/env"
  status=0
  if [ "$config" = - ]; then
    env -i PATH="$PATH" GITHUB_ENV="$dir/env" bash "$script" >"$dir/log" 2>&1 || status=$?
  else
    env -i PATH="$PATH" GITHUB_ENV="$dir/env" NIX_CONFIG="$config" \
      bash "$script" >"$dir/log" 2>&1 || status=$?
  fi
}

# exported FILE: the last NIX_CONFIG a $GITHUB_ENV file sets, in either form.
exported() {
  local file="$1" line delim="" value="" collecting=false found=false
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$collecting" = true ]; then
      if [ "$line" = "$delim" ]; then
        collecting=false
      else
        value+="$line"$'\n'
      fi
    elif [ "${line#NIX_CONFIG<<}" != "$line" ]; then
      delim="${line#NIX_CONFIG<<}"
      value=""
      collecting=true
      found=true
    elif [ "${line#NIX_CONFIG=}" != "$line" ]; then
      value="${line#NIX_CONFIG=}"$'\n'
      found=true
    fi
  done <"$file"
  [ "$found" = true ] || return 1
  printf '%s' "${value%$'\n'}"
}

features_on() { # features_on CONFIG: both features effective under CONFIG
  local shown
  shown="$(nix_with "$1" config show experimental-features 2>&1)" || return 1
  case " $shown " in *" nix-command "*) ;; *) return 1 ;; esac
  case " $shown " in *" flakes "*) ;; *) return 1 ;; esac
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

# 0. The fixture reproduces the job's failure.
if out="$(nix_with "$INCLUDE" config show experimental-features 2>&1)"; then
  fail "fixture: the unconfigured nix already runs the new CLI ($out); the cases below would prove nothing"
elif [[ "$out" == *"experimental Nix feature 'nix-command' is disabled"* ]]; then
  pass "fixture: the job's NIX_CONFIG leaves nix-command disabled (the defect)"
else
  fail "fixture: unexpected failure of the unconfigured nix: $out"
fi

# 1. The script enables both features and keeps the include, first.
run_script "$SCRIPT" "$TMP/c1" "$INCLUDE"
if [ "$status" = 0 ] && c1="$(exported "$TMP/c1/env")" &&
  [ "$c1" = "$INCLUDE"$'\n'"$SETTING" ] && features_on "$c1"; then
  pass "the exported NIX_CONFIG keeps the include and enables nix-command and flakes"
else
  fail "case 1: status=$status exported='$(exported "$TMP/c1/env")' log=$(cat "$TMP/c1/log")"
fi

# 1m. Control: a script that does not append the setting fails case 1.
mutate "$TMP/mutant.sh" '  config="${config}"$'"'"'\n'"'"'"${SETTING}"' '  config="${config}"'
run_script "$TMP/mutant.sh" "$TMP/c1m" "$INCLUDE"
if c1m="$(exported "$TMP/c1m/env")" && features_on "$c1m"; then
  fail "control: the mutant that does not append the setting still enables the features"
else
  pass "control: without the appended setting the new CLI stays disabled (case 1 is a real test)"
fi

# 2. The Nix authentication step that runs next keeps the line.
mkdir -p "$TMP/c2/runner-temp"
cp "$TMP/c1/env" "$TMP/c2/env"
status=0
env -i PATH="$PATH" HOME="$TMP/c2" GITHUB_ENV="$TMP/c2/env" \
  RUNNER_TEMP="$TMP/c2/runner-temp" GH_TOKEN=fresh-fixture-not-a-credential \
  TOKEN_OWNERS=metacraft-labs NIX_CONF_DIR="$TMP/etc" \
  NIX_USER_CONF_FILES="$TMP/empty.conf" XDG_CONFIG_HOME="$TMP/xdg" \
  NIX_CONFIG="$c1" "$NODE_BIN" -e 'require(process.argv[1]).refreshNix()' \
  "$NIX_AUTH" >"$TMP/c2/log" 2>&1 || status=$?
c2="$(exported "$TMP/c2/env" || true)"
if [ "$status" = 0 ] && [[ $'\n'"$c2"$'\n' == *$'\n'"$SETTING"$'\n'* ]] && features_on "$c2"; then
  pass "the Nix authentication step keeps the setting"
else
  fail "case 2: status=$status exported='$c2' log=$(cat "$TMP/c2/log")"
fi

# 3. Additive: a base experimental-features list is kept.
run_script "$SCRIPT" "$TMP/c3" "experimental-features = pipe-operators"
c3="$(exported "$TMP/c3/env" || true)"
shown="$(nix_with "$c3" config show experimental-features 2>&1 || true)"
if [ "$status" = 0 ] && [[ " $shown " == *" pipe-operators "* ]] && features_on "$c3"; then
  pass "features a host already enables are kept"
else
  fail "case 3: status=$status exported='$c3' shown='$shown'"
fi

# 4. Idempotent, and an unset NIX_CONFIG gets the setting alone.
run_script "$SCRIPT" "$TMP/c4" -
first="$(cat "$TMP/c4/env")"
c4="$(exported "$TMP/c4/env" || true)"
run_script "$SCRIPT" "$TMP/c4" "$c4"
if [ "$status" = 0 ] && [ "$c4" = "$SETTING" ] && [ "$(cat "$TMP/c4/env")" = "$first" ] &&
  grep -q 'already enables nix-command and flakes; unchanged' "$TMP/c4/log"; then
  pass "an unset NIX_CONFIG gets the setting; a second run changes nothing"
else
  fail "case 4: status=$status exported='$c4' env='$(cat "$TMP/c4/env")' log=$(cat "$TMP/c4/log")"
fi

# 5. A credential is kept verbatim and never printed. Trailing newlines go.
secret="github.com=inline-fixture-not-a-credential"
run_script "$SCRIPT" "$TMP/c5" "access-tokens = $secret"$'\n'"http-connections = 7"$'\n\n'
c5="$(exported "$TMP/c5/env" || true)"
if [ "$status" = 0 ] &&
  [ "$c5" = "access-tokens = $secret"$'\n'"http-connections = 7"$'\n'"$SETTING" ] &&
  ! grep -q 'inline-fixture-not-a-credential' "$TMP/c5/log"; then
  pass "every existing line is kept in order, and the value is not printed"
else
  fail "case 5: status=$status exported='$c5' log=$(cat "$TMP/c5/log")"
fi

# 6. No $GITHUB_ENV: a failure, not a silent no-op.
status=0
env -i PATH="$PATH" NIX_CONFIG="$INCLUDE" bash "$SCRIPT" >"$TMP/c6.log" 2>&1 || status=$?
if [ "$status" != 0 ] && grep -q '^::error::enable-nix-features: GITHUB_ENV is not set' "$TMP/c6.log"; then
  pass "without GITHUB_ENV the script fails and says why"
else
  fail "case 6: status=$status log=$(cat "$TMP/c6.log")"
fi

# 7. Wiring in action.yml.
step_line() { grep -n -F -- "- name: $1" "$ACTION" | head -n 1 | cut -d: -f1; }
enable="$(step_line 'Enable the Nix features the dev env uses (reprobuild)')"
install="$(step_line 'Install Nix for the dev env (reprobuild)')"
archive="$(step_line 'Ensure the archive tools repro shells out to (reprobuild)')"
auth="$(step_line 'Configure Nix authentication (reprobuild)')"
witness="$(step_line 'Verify Reprobuild development-environment execution')"
if [ -n "$enable" ] && [ -n "$install" ] && [ -n "$archive" ] && [ -n "$auth" ] &&
  [ -n "$witness" ] && [ "$install" -lt "$enable" ] && [ "$enable" -lt "$archive" ] &&
  [ "$enable" -lt "$auth" ] && [ "$enable" -lt "$witness" ]; then
  pass "the step runs after the Nix install and before any step that runs nix or repro"
else
  fail "case 7: step order enable=$enable install=$install archive=$archive auth=$auth witness=$witness"
fi
body="$(sed -n "${enable},$((enable + 3))p" "$ACTION")"
if [[ "$body" == *"if: \${{ inputs.env-flavor == 'reprobuild' && runner.os != 'Windows' }}"* ]] &&
  [[ "$body" == *'run: bash "${GITHUB_ACTION_PATH}/enable-nix-features.sh"'* ]]; then
  pass "the step runs the script for the reprobuild flavor, never on Windows"
else
  fail "case 7: unexpected step body: $body"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
