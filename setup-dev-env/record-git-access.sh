#!/usr/bin/env bash
#
# record-git-access.sh -- record `git-access: none` in the job's credential
# directory, before anything installs a Git credential.
#
# Every installer of the job-scoped Git credential (setup-nix's
# configure-git-auth.sh, setup-dev-env's "Configure Git authentication
# (reprobuild)" and refresh-build-auth) goes through
# ../git-auth/scoped-git-auth.sh, whose scoped_git_auth_emit reads
# `<credential dir>/git-access` and writes nothing for `none`. The broker
# (refresh-build-auth/job-credentials.cjs) reads the same file and never
# writes the Git token. Recording it here, at the start, is what makes all of
# them agree, including the steps that run on Windows, where no broker starts.
#
# The directory is the job's existing one when a broker or an earlier
# setup-nix made it, and a new private one under RUNNER_TEMP otherwise, which
# is then exported as MCL_JOB_CREDENTIALS_DIR so every later step uses it.
#
# Outputs, for the closing check (check-git-config-untouched.sh): the job's
# GIT_CONFIG_COUNT and GIT_CONFIG_PARAMETERS as this step found them, `unset`
# when absent.
#
# Environment: GIT_ACCESS (the input), GITHUB_ENV, GITHUB_OUTPUT, RUNNER_TEMP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "$HERE/../git-auth/scoped-git-auth.sh"

: "${GITHUB_ENV:?GitHub Actions did not set GITHUB_ENV}"
: "${GITHUB_OUTPUT:?GitHub Actions did not set GITHUB_OUTPUT}"
case "${GIT_ACCESS:-}" in
none) ;;
*)
  echo "::error::record-git-access: only git-access none is recorded here (got '${GIT_ACCESS:-}')" >&2
  exit 1
  ;;
esac

scoped_git_auth_job_dir
printf '%s\n' "$GIT_ACCESS" >"$SCOPED_GIT_AUTH_JOB_DIR/git-access"
if [[ $SCOPED_GIT_AUTH_JOB_DIR_CREATED == 1 ]]; then
  printf 'MCL_JOB_CREDENTIALS_DIR=%s\n' "$SCOPED_GIT_AUTH_JOB_DIR" >>"$GITHUB_ENV"
fi
{
  printf 'git-config-count=%s\n' "${GIT_CONFIG_COUNT-unset}"
  if [[ -n ${GIT_CONFIG_PARAMETERS+set} ]]; then
    printf 'git-config-parameters=set\n'
  else
    printf 'git-config-parameters=unset\n'
  fi
} >>"$GITHUB_OUTPUT"
echo "setup-dev-env: git-access none recorded; no job-scoped Git credential will be installed"
