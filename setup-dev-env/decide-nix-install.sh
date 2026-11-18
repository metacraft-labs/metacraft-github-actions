#!/usr/bin/env bash
#
# decide-nix-install.sh — under `env-flavor: reprobuild`, decide whether this
# job must install Nix before the first `repro exec`, and say why.
#
# WHAT THIS FIXES
# ---------------
# `setup-reprobuild` installs Nix only to BUILD `repro` from source. When it
# installs the prebuilt release instead, it installs no Nix, which is right for
# the CLI itself. But a consumer's `repro.nim` can activate a flake dev shell
# (`useFlakeDevShell()`), and Nix tool provisioning needs a Nix client too.
# Neither works without a `nix` on PATH. On a host that has no Nix, such as an
# ephemeral VM of the runner fleet, the setup witness then failed with
# `useFlakeDevShell needs nix on PATH (or REPRO_FOREIGN_ENV_NIX)`. The same
# consumer had passed on persistent NixOS hosts, which carry Nix. A source
# build masked the gap as well, because it installs Nix as a side effect.
#
# THE DECISION, IN ORDER
# ----------------------
#   windows  — RUNNER_OS is Windows. The reprobuild flavor provisions Windows
#              without Nix (env.ps1 / the DIY contract). Nothing is installed.
#   present  — a `nix` is already on PATH: the host's own, or the one a source
#              build of `repro` installed in an earlier step. Nothing is
#              installed. The action's later Nix authentication step applies
#              the job's token to it, as before.
#   nixos    — a NixOS host (MCL_NIXOS_HOST=true, from
#              decide-tool-provisioning.sh's `nixos-host` output) without
#              `nix` on PATH. The system Nix belongs to the host configuration,
#              and installing a second one beside it would fight the system
#              daemon. Nothing is installed, and a warning says the dev env
#              will not activate.
#   install  — anything else: Linux or macOS with no `nix` on PATH. The
#              action then runs `setup-nix`, the same action the source build
#              and the `nix` flavor use, so the substituters, trusted keys,
#              netrc and Git credential are configured exactly as there.
#
# WHY "NIX IS ABSENT", NOT "THE RELEASE WAS INSTALLED"
# ----------------------------------------------------
# What the dev env needs is a `nix` on PATH. How `repro` got there does not
# matter: a release install on a host with Nix needs nothing, and a source
# build has already installed Nix, so testing for the binary covers both
# without a second installer run.
#
# WHY UNCONDITIONALLY, NOT ONLY WHEN THE CONSUMER NEEDS NIX
# ---------------------------------------------------------
# Whether a consumer needs Nix is decided by evaluating its `repro.nim`
# (`useFlakeDevShell()`, Nix tool provisioning, a dependency's dev env). A
# text probe for that would be easy to defeat and would fail late, inside the
# first `repro exec`. The cost of installing Nix where it was not needed is
# one installer run on a host that had none; the cost of skipping it where it
# was needed is a failed job. So every reprobuild-flavor job on a Linux or
# macOS host without Nix gets one.
#
# It never fails the job, and always prints its decision.
#
# PORTABILITY. bash 3.2 (GitHub's macOS images) and Git Bash on Windows; bash
# builtins only.
#
# INPUTS arrive as environment variables:
#   RUNNER_OS        set by the runner (Linux, macOS, Windows)
#   MCL_NIXOS_HOST   `true` on a NixOS host
# Outputs: `install-nix` (`true` or `false`) and `nix-install-source` (the
# DECISION) to $GITHUB_OUTPUT, and one line to the log and
# $GITHUB_STEP_SUMMARY on every path.
set -euo pipefail

DECISION=""
REASON=""

if [ "${RUNNER_OS:-}" = Windows ]; then
  DECISION="windows"
  REASON="Windows runner: the reprobuild flavor provisions Windows without Nix"
elif command -v nix >/dev/null 2>&1; then
  DECISION="present"
  REASON="nix is already on PATH; installing nothing"
elif [ "${MCL_NIXOS_HOST:-}" = true ]; then
  DECISION="nixos"
  REASON="NixOS runner without nix on PATH; its system Nix is not reinstalled"
else
  DECISION="install"
  REASON="nix is not on PATH; installing it with setup-nix, because the consumer's dev env and Nix tool provisioning run through it"
fi

INSTALL=false
if [ "$DECISION" = install ]; then
  INSTALL=true
  echo "::notice::setup-dev-env: Nix: ${DECISION}: ${REASON}"
else
  echo "setup-dev-env: Nix: ${DECISION}: ${REASON}"
fi
if [ "$DECISION" = nixos ]; then
  echo "::warning::setup-dev-env: this NixOS runner has no \`nix\` on PATH; a flake dev shell or Nix tool provisioning will fail" >&2
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- Nix: \`${DECISION}\` — ${REASON}" >>"$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "install-nix=${INSTALL}"
    echo "nix-install-source=${DECISION}"
  } >>"$GITHUB_OUTPUT"
fi
exit 0
