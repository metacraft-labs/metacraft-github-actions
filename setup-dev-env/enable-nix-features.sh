#!/usr/bin/env bash
#
# enable-nix-features.sh — under `env-flavor: reprobuild`, enable the Nix
# experimental features `nix-command` and `flakes` for every later step of the
# job, whatever configured the `nix` on PATH.
#
# WHAT THIS FIXES
# ---------------
# decide-nix-install.sh installs nothing when a `nix` is already on PATH
# (decision `present`), so setup-nix -- which writes
# `extra-experimental-features = nix-command flakes` into the user nix.conf --
# never runs. The `nix` found that way is not necessarily configured for the
# new CLI. The ephemeral Linux runners of the fleet get theirs from the GARM
# provider: `/usr/local/bin/nix` is a wrapper that runs the HOST's Nix client
# against the host daemon (NIX_REMOTE=daemon), but the guest has no nix.conf,
# so the client starts with Nix's defaults, in which both features are off.
# The first `repro exec` then failed inside the consumer's flake dev shell:
#
#   /usr/local/bin/nix print-dev-env --no-write-lock-file --profile … .?submodules=1
#   error: experimental Nix feature 'nix-command' is disabled
#
# (codetracer-shell-recorders job 138310567518 and codetracer-move-recorder
# job 138310633875, 2026-11-24.) 8b9f60a passed the option to this action's own
# `nix` calls; the calls `repro` makes are not this action's to spell, and the
# consumer's own steps make more. So the job's NIX_CONFIG carries the setting
# instead: Nix reads NIX_CONFIG after its configuration files, in every client
# a later step starts, and repro forwards it to the Nix commands it runs.
#
# WHY `extra-`. `extra-experimental-features` appends to the configured list
# and removes nothing (https://nix.dev/manual/nix/latest/command-ref/conf-file
# "extra-"), so a host that already enables more features -- NixOS runners
# enable pipe-operators -- keeps them, and a host that already enables these
# two is unchanged. That is why the step runs on every Linux and macOS job of
# the flavor and does not first ask whether the features are on.
#
# WHAT IS KEPT. Every line already in NIX_CONFIG is kept as it is, in order;
# the setting is appended once, and not again if an identical line is already
# there (a composite action can run twice in a job). The value can hold
# credentials (`access-tokens`), so it is never printed.
#
# PORTABILITY. bash 3.2 (GitHub's macOS images); bash builtins only.
#
# INPUTS arrive as environment variables:
#   NIX_CONFIG   the job's current value, possibly unset
#   GITHUB_ENV   the runner's environment file (required)
# Output: NIX_CONFIG for later steps, through $GITHUB_ENV, and one line to the
# log.
set -euo pipefail

readonly SETTING="extra-experimental-features = nix-command flakes"

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::enable-nix-features: GITHUB_ENV is not set; cannot export NIX_CONFIG to later steps" >&2
  exit 1
fi

config="${NIX_CONFIG:-}"
# Drop trailing newlines so the appended line is not separated by blank ones.
while [ "${config%$'\n'}" != "$config" ]; do
  config="${config%$'\n'}"
done

present=false
while IFS= read -r line; do
  if [ "$line" = "$SETTING" ]; then present=true; fi
done <<<"$config"

if [ "$present" = true ]; then
  echo "setup-dev-env: Nix: NIX_CONFIG already enables nix-command and flakes; unchanged"
  exit 0
fi

if [ -n "$config" ]; then
  config="${config}"$'\n'"${SETTING}"
else
  config="$SETTING"
fi

# A multi-line value goes through the heredoc form of $GITHUB_ENV
# (https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#multiline-strings).
# The delimiter must not occur in the value as a line of its own.
delimiter="nix_features_${RANDOM}${RANDOM}${RANDOM}"
while case $'\n'"$config"$'\n' in *$'\n'"$delimiter"$'\n'*) true ;; *) false ;; esac; do
  delimiter="nix_features_${RANDOM}${RANDOM}${RANDOM}"
done
{
  printf 'NIX_CONFIG<<%s\n' "$delimiter"
  printf '%s\n' "$config"
  printf '%s\n' "$delimiter"
} >>"$GITHUB_ENV"

echo "setup-dev-env: Nix: enabled nix-command and flakes for the later steps of this job (${SETTING} in NIX_CONFIG)"
