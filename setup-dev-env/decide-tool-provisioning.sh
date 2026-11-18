#!/usr/bin/env bash
#
# decide-tool-provisioning.sh — on a NixOS runner, make `repro` provision the
# tools a project declares with Nix, and say why.
#
# WHAT THIS FIXES
# ---------------
# A project's `repro.nim` declares the tools its build uses. `repro` realises
# them in one of several provisioning modes (`path`, `nix`, `tarball`, ...),
# chosen by, in decreasing precedence:
#
#   1. `--tool-provisioning=<mode>` on the command line (`repro build`,
#      `repro test` and the other build-family verbs; activation verbs such as
#      `repro exec` and `repro shell` have no such flag),
#   2. the `REPRO_TOOL_PROVISIONING` environment variable (read by the
#      build-family verbs AND by dev-env activation, i.e. `repro exec`),
#   3. the project's own `defaultToolProvisioning`.
#
# Where a declared tool is not found on PATH, the non-Nix modes fall back to
# downloading the vendor's generic-Linux release tarball. Those binaries are
# dynamically linked against the FHS loader `/lib64/ld-linux-x86-64.so.2`. On
# NixOS that path is a stub that refuses to start foreign binaries, so the
# tool is realised and then cannot run; `repro` detects this and fails naming
# the loader and the remedy (Nix provisioning). This was seen on a NixOS
# persistent runner with a recorder project whose build needs `forc`. In
# addition, `path` mode is becoming strictly PATH-only, so NixOS CI cannot
# rely on it to obtain anything the runner image does not already carry.
#
# The remedy is Nix provisioning, which realises each tool as a Nix store
# path whose loader and libraries are part of the closure. This script selects
# it for the rest of the job on NixOS runners.
#
# WHY THE ENVIRONMENT VARIABLE, AND WHY $GITHUB_ENV
# ------------------------------------------------
# The variable is the one selector every relevant verb honours: `repro exec`
# (the activation behind `dev-exec <cmd>` and the setup witness), and
# `repro build` / `repro test` (which `dev-exec` runs directly). A flag added
# inside the `dev-exec` wrapper would miss `repro exec`, which refuses the
# flag, and any step that calls `repro` without the wrapper. Written to
# $GITHUB_ENV, it reaches every SUBSEQUENT step of the job, including the
# caller's. The step runs before the first `repro exec` of this action for
# that reason: $GITHUB_ENV is not visible to the step that writes it.
#
# PRECEDENCE: AN EXPLICIT CHOICE WINS
# -----------------------------------
#   - A `--tool-provisioning=<mode>` flag passed to `repro build`/`repro test`
#     outranks the variable inside `repro` itself; this script cannot and does
#     not interfere with it. `dev-exec` passes such a flag through unchanged.
#   - A non-empty `REPRO_TOOL_PROVISIONING` already in the environment when
#     this action runs (set in the job's `env:`, or written to $GITHUB_ENV by an
#     earlier step) is left alone and reported. A caller that wants the
#     project's declared default on NixOS sets the mode it declares
#     explicitly. Set it at job level: a value given only in the `env:` of the
#     step that uses this action would not reach the caller's later steps.
#   - An empty value counts as unset, as it does in `repro`.
#
# NIXOS DETECTION
# ---------------
# Either signal suffices: the `/etc/NIXOS` marker file that every NixOS system
# carries, or `ID=nixos` in `/etc/os-release`
# (https://www.freedesktop.org/software/systemd/man/latest/os-release.html).
# A Nix installation on another distribution, or on macOS, is NOT NixOS: it
# has a working FHS loader, so tarballs run there and nothing is exported.
# Windows (Git Bash) has neither file.
#
# NIX ITSELF
# ----------
# Nix provisioning needs a working `nix` client, a reachable Nix daemon and
# substituters. On a NixOS runner all three are part of the host: the system
# daemon runs and the system `nix.conf` names the binary caches. This action
# installs nothing for it; the "Configure Nix authentication" step only adds
# the job's GitHub token for private flake inputs. When `nix` is not on PATH
# the decision still stands (nothing else can run tools on that host), and a
# warning says so, because the first tool realisation will then fail.
#
# It never fails the job, and always prints its decision.
#
# PORTABILITY. bash 3.2 (GitHub's macOS images) and Git Bash on Windows; bash
# builtins only, no awk/sed/grep.
#
# INPUTS arrive as environment variables (the contract suite overrides the
# first two so it never reads the real host files):
#   MCL_NIXOS_MARKER   default /etc/NIXOS
#   MCL_OS_RELEASE     default /etc/os-release
# Outputs: `tool-provisioning` (the exported mode, or empty),
# `tool-provisioning-source` (the DECISION) and `nixos-host` (`true` or
# `false`, whatever the DECISION) to $GITHUB_OUTPUT,
# REPRO_TOOL_PROVISIONING to $GITHUB_ENV when exported, and one line to the
# log and $GITHUB_STEP_SUMMARY on every path.
set -euo pipefail

MARKER="${MCL_NIXOS_MARKER-/etc/NIXOS}"
OS_RELEASE="${MCL_OS_RELEASE-/etc/os-release}"

# os_release_is_nixos: does the os-release file say ID=nixos (quoted or not)?
os_release_is_nixos() {
  [ -n "$OS_RELEASE" ] && [ -r "$OS_RELEASE" ] || return 1
  local line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    ID=*)
      value="${line#ID=}"
      value="${value%$'\r'}"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      [ "$value" = nixos ] && return 0
      return 1
      ;;
    esac
  done <"$OS_RELEASE"
  return 1
}

# DECISION is one of:
#   caller     — REPRO_TOOL_PROVISIONING was already set; untouched.
#   nixos      — this is a NixOS host; REPRO_TOOL_PROVISIONING=nix exported.
#   not-nixos  — nothing exported; the project's declared mode applies.
DECISION=""
REASON=""
MODE=""

# Whether this host is NixOS, independently of the decision below: a caller's
# own REPRO_TOOL_PROVISIONING settles the mode but not what the host is, and
# decide-nix-install.sh reads this output to leave a NixOS system Nix alone.
NIXOS_HOST=false
if { [ -n "$MARKER" ] && [ -e "$MARKER" ]; } || os_release_is_nixos; then
  NIXOS_HOST=true
fi

if [ -n "${REPRO_TOOL_PROVISIONING:-}" ]; then
  DECISION="caller"
  REASON="REPRO_TOOL_PROVISIONING was already set to ${REPRO_TOOL_PROVISIONING} before this action ran; leaving it alone"
elif [ "$NIXOS_HOST" = true ]; then
  DECISION="nixos"
  MODE="nix"
  REASON="NixOS runner: exporting REPRO_TOOL_PROVISIONING=nix, because NixOS cannot run the generic-Linux tool tarballs the other modes fall back to (an explicit --tool-provisioning flag still wins)"
else
  DECISION="not-nixos"
  REASON="not a NixOS runner; the project's declared tool provisioning applies"
fi

# A chosen mode is a `::notice::` so it shows among the run's annotations: a
# reader puzzled by Nix realisations in the log finds the reason there.
if [ "$DECISION" = nixos ]; then
  echo "::notice::setup-dev-env: tool provisioning: ${DECISION}: ${REASON}"
else
  echo "setup-dev-env: tool provisioning: ${DECISION}: ${REASON}"
fi
if [ "$DECISION" = nixos ] && ! command -v nix >/dev/null 2>&1; then
  echo "::warning::setup-dev-env: Nix tool provisioning was selected on this NixOS runner, but no \`nix\` is on PATH; repro will fail to realise declared tools" >&2
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- Tool provisioning: \`${DECISION}\` — ${REASON}" >>"$GITHUB_STEP_SUMMARY"
fi
if [ -n "$MODE" ] && [ -n "${GITHUB_ENV:-}" ]; then
  echo "REPRO_TOOL_PROVISIONING=${MODE}" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "tool-provisioning=${MODE}"
    echo "tool-provisioning-source=${DECISION}"
    echo "nixos-host=${NIXOS_HOST}"
  } >>"$GITHUB_OUTPUT"
fi
exit 0
