#!/usr/bin/env bash
#
# check-git-config-untouched.sh -- the closing check of `git-access: none`:
# fail when the job's Git runtime configuration differs from what
# record-git-access.sh found at the start of the action.
#
# GIT_CONFIG_COUNT is compared by value; a job-scoped credential installed
# anyway always changes it. GIT_CONFIG_PARAMETERS is compared by presence,
# because its value is not recorded (it may carry a credential).
#
# Environment: START_GIT_CONFIG_COUNT and START_GIT_CONFIG_PARAMETERS, the
# recording step's outputs (`unset` when absent; `set`/`unset` for the latter).
set -euo pipefail

now_count="${GIT_CONFIG_COUNT-unset}"
if [[ -n ${GIT_CONFIG_PARAMETERS+set} ]]; then now_parameters='set'; else now_parameters='unset'; fi
start_count="${START_GIT_CONFIG_COUNT:-unset}"
start_parameters="${START_GIT_CONFIG_PARAMETERS:-unset}"

if [[ $now_count != "$start_count" || $now_parameters != "$start_parameters" ]]; then
  echo "::error::setup-dev-env: git-access none, but the job's Git configuration changed during this action (GIT_CONFIG_COUNT ${start_count} -> ${now_count}, GIT_CONFIG_PARAMETERS ${start_parameters} -> ${now_parameters}). An installer did not honour the recorded declaration." >&2
  exit 1
fi
echo "setup-dev-env: git-access none held; the job's Git configuration is as this action found it"
