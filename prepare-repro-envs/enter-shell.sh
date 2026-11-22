#!/usr/bin/env bash
# Use the caller's existing SDK shell and retain its normal Nix profile for
# the job. Nix and Repro continue to own selection and realization lifetimes.
set -euo pipefail
: "${REPRO_PREFLIGHT_NIX_SHELL:?the existing build shell is required}"
: "${GITHUB_ACTION_PATH:?the shared action path is required}"
cd "${REPRO_PREFLIGHT_WORKING_DIRECTORY:?the existing build directory is required}"
profile=$(mktemp -d "${RUNNER_TEMP:?RUNNER_TEMP is required}/repro-preflight-shell.XXXXXX")
# `nix develop` and a flake reference are the new CLI and flakes; enable them
# here rather than depend on the caller's nix.conf (the option only adds).
if nix --extra-experimental-features 'nix-command flakes' develop --profile "$profile/profile" "$REPRO_PREFLIGHT_NIX_SHELL" --command bash "$GITHUB_ACTION_PATH/prepare.sh"; then
  exit 0
else
  status=$?
  printf '::error::infrastructure preparation failed in selected shell %s (exit %s); the Nix or SDK diagnostic above is the cause\n' "$REPRO_PREFLIGHT_NIX_SHELL" "$status" >&2
  exit "$status"
fi
