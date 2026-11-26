#!/usr/bin/env bash
#
# substitute-repro-package.sh — install the selected Reprobuild commit's Nix
# package from a binary cache when a cache holds it, so the job does not
# compile the engine from source.
#
# The selected commit is built once, and every later job reuses that build.
# Reprobuild's release pipeline pushes `github:metacraft-labs/reprobuild/<rev>#reprobuild`
# for x86_64-linux to the organisation's Attic cache (its `publish-nix-cache`
# job), and this repository's `pins` workflow (its `reprobuild-cache` job, on
# self-hosted runners that reach the cache) pushes the pinned revision's
# package for x86_64-linux and aarch64-darwin when the pin changes on agents or
# dev. A job whose Nix trusts and reaches that cache then only has to download
# the package; a hosted runner reaches no such cache and builds from source.
# Before this step, the source route compiled the engine in Reprobuild's dev
# shell (`just build`) on every Linux job, for about 30-50 minutes, whether or
# not the cache already held the package.
#
# The package is still a build of the selected source revision: its store path
# is a function of that revision and its locked inputs, and the admission below
# accepts only the output that the pinned flake evaluates to on this system.
#
# This script only ever SUBSTITUTES. `nix build --max-jobs 0` may download the
# output and its closure, and may not build anything. So a cache miss costs
# one evaluation, about a minute, and the caller then takes the source route
# exactly as before. A miss is not an error, and neither is a cache that cannot
# be reached: both are announced, and the source build still produces the
# selected engine. A package that WAS substituted and then fails admission is
# an error: that is a wrong artifact, not a missing one.
#
# Inputs (environment):
#   REPRO_BUILD_PIN  the selected commit, a full lowercase SHA
#   GH_TOKEN         optional; reaches nix through NIX_CONFIG, never argv
#                    (the flake's locked inputs include private repositories)
#   RUNNER_TEMP      scratch directory for nix's diagnostics
#   GITHUB_OUTPUT, GITHUB_PATH, GITHUB_ENV
# Outputs: `bin-dir=<package>/bin` on a hit (written by bind-repro-package.sh);
# nothing on a miss.
#
# Bash builtins only, besides nix: the job's PATH can be a Nix profile without
# coreutils.
set -uo pipefail

# Git Bash on Windows may name this script with backslashes; the action never
# runs it there, but keep the directory computation identical to its siblings.
script_path="${BASH_SOURCE[0]//\\//}"
script_dir="${script_path%/*}"
[ "${script_dir}" = "${script_path}" ] && script_dir=.

pin="${REPRO_BUILD_PIN:-}"

if [ "${RUNNER_OS:-}" = Windows ]; then
  echo "::error::setup-reprobuild: the binary-cache route is a Nix route; Windows has none"
  exit 1
fi
if [[ ! "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
  # Only an immutable revision identifies one package. The action's condition
  # already requires the full SHA, so this is defence in depth.
  echo "::notice::setup-reprobuild: '${pin}' is not a full commit SHA; not consulting the binary cache"
  exit 0
fi
if ! command -v nix >/dev/null 2>&1; then
  echo "::warning::setup-reprobuild: no nix on PATH, so the binary cache cannot be consulted; building repro from source"
  exit 0
fi

if [ -n "${GH_TOKEN:-}" ]; then
  newline=$'\n'
  NIX_CONFIG="${NIX_CONFIG:+${NIX_CONFIG}${newline}}access-tokens = github.com=${GH_TOKEN}"
  export NIX_CONFIG
fi

# The same reference bind-repro-package.sh evaluates and reprobuild's
# `publish-nix-cache` job pushes, so the store path asked for here is the one
# the cache was given.
flake="github:metacraft-labs/reprobuild/${pin}"
log="${RUNNER_TEMP:-/tmp}/setup-reprobuild-substitute.log"

echo "setup-reprobuild: asking the configured binary caches for ${flake}#reprobuild"
# --max-jobs 0: no local build at all. When the output path is valid in a
# substituter, Nix downloads it and its runtime closure; when it is not, Nix
# refuses instead of compiling it. Nix 2.34 says "local builds are disabled
# (max-jobs = 0)"; older releases say "unable to start any build".
# --builders '': max-jobs 0 only disables LOCAL builds. A host whose nix.conf
# names remote builders (`builders = @/etc/nix/machines` on the organisation's
# self-hosted machines) would otherwise send the whole engine build to them,
# which is the compile this step exists to avoid, and not a download.
# https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-max-jobs
# https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-builders
out="$(nix --extra-experimental-features 'nix-command flakes' build \
  --no-link --print-out-paths --no-update-lock-file --max-jobs 0 --builders '' \
  "${flake}#reprobuild" 2>"${log}")"
status=$?
diagnostics=""
[ -f "${log}" ] && diagnostics="$(<"${log}")"

if [ "${status}" -ne 0 ] || [ -z "${out}" ]; then
  refused_build=false
  case "${diagnostics}" in
    *"local builds are disabled"* | *"unable to start any build"*) refused_build=true ;;
  esac
  # A substituter that failed is disabled by Nix for the rest of the command,
  # and the build is then refused as for a miss. Report that as cache trouble,
  # not as a miss, or an unreachable cache would look like an empty one.
  cache_trouble=false
  case "${diagnostics}" in
    *"HTTP error"* | *"unable to download"* | *" is disabled"*) cache_trouble=true ;;
  esac
  case "${refused_build}:${cache_trouble}" in
    true:false)
      echo "::notice::setup-reprobuild: no configured binary cache holds ${flake}#reprobuild; building repro from source" ;;
    *)
      # Evaluation, network or credential trouble. The source route does not
      # depend on any of it succeeding here, so it still runs; the reason is
      # printed so a cache that never answers is visible, not inferred.
      last="${diagnostics##*$'\n'}"
      echo "::warning::setup-reprobuild: could not consult the binary cache for ${flake}#reprobuild (nix exit ${status}: ${last}); building repro from source" ;;
  esac
  if [ -n "${diagnostics}" ]; then
    echo "::group::nix output"
    printf '%s\n' "${diagnostics}"
    echo "::endgroup::"
  fi
  exit 0
fi

# One output, one line; take the first in case Nix ever prints more.
out="${out%%$'\n'*}"
echo "setup-reprobuild: substituted ${out} from the binary cache"

# Admit it exactly as a caller-built package is admitted: it must be the
# package output the pinned flake evaluates to here, and carry the CLI and the
# Nix daemon helper. bind-repro-package.sh puts its bin/ on PATH and writes
# `bin-dir`.
REPRO_PACKAGE="${out}" REPRO_BUILD_PIN="${pin}" bash "${script_dir}/bind-repro-package.sh"
