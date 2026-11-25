#!/usr/bin/env bash
#
# install-pin-release.sh — install the selected Reprobuild commit from its
# per-pin prerelease when one is published, so a Windows job does not compile
# the engine from source.
#
# The selected commit is built once, and every later job reuses that build.
# On Linux that build is the commit's Nix package in the organisation's binary
# cache (substitute-repro-package.sh). Windows has no Nix, and its source build
# needs reprobuild's env.ps1 toolchains and a dozen sibling checkouts, so the
# reusable form there is the release-style bundle reprobuild's own packaging
# script makes (scripts/release/package_windows_release.ps1). This repository's
# `pins` workflow builds the pinned commit from source on a Windows runner,
# packages it with that script and publishes it as the prerelease
#
#   tag      pin-<full commit SHA>
#   assets   reprobuild-<version>-windows-x86_64.zip
#            SHA256SUMS
#
# in THIS repository (metacraft-labs/metacraft-github-actions), never in
# reprobuild: it is a pin-scoped build, not a Reprobuild release, and a
# prerelease is never "Latest". Before this route every Windows job built the
# pin from source: about 16-19 minutes on win-ci-bare-001, and over the
# six-hour job limit on the GARM and VM Windows runners.
#
# It is installed through install-release.sh, the same verified path as a
# Reprobuild release: SHA256SUMS first, the archive checked against it, the
# tree unpacked and contained, and the installed CLI run. Verification is
# always required here; `require-checksum: false` does not reach this route.
#
# Exit status, and what the caller does with it:
#   0  installed: `bin-dir=<dir>` is written to GITHUB_OUTPUT and the
#      directory to GITHUB_PATH; or nothing was installed because there is
#      nothing to install (no prerelease for this commit, no archive for this
#      platform, a selection that is not a full SHA). The caller takes the
#      source route exactly as before.
#   1  the prerelease exists and is WRONG: a checksum mismatch, a corrupt or
#      escaping archive, a CLI that does not run or reports another version.
#      Never fall back to a source build on this; it is the event the
#      verification exists to catch.
#
# Inputs (environment):
#   REPRO_BUILD_PIN          the selected commit, a full lowercase SHA
#   EXPECTED_VERSION         the version the pin names, when the caller knows
#                            it; empty reads it from the prerelease's
#                            SHA256SUMS (setup-dev-env forwards the pin as a
#                            plain commit, so setup-reprobuild may not know it)
#   REPRO_PIN_RELEASE_REPO   the repository holding the prereleases; default
#                            metacraft-labs/metacraft-github-actions
#   REPRO_GITHUB_TOKEN       optional, forwarded to install-release.sh
#   RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_PATH
#   REPRO_RELEASE_DOWNLOAD_ORIGIN / REPRO_RELEASE_API_ORIGIN (tests only)
#
# Bash builtins only, besides install-release.sh: the job's PATH can be a
# profile without coreutils.
set -uo pipefail

script_path="${BASH_SOURCE[0]//\\//}"
script_dir="${script_path%/*}"
[ "${script_dir}" = "${script_path}" ] && script_dir=.

pin="${REPRO_BUILD_PIN:-}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
: "${GITHUB_PATH:?GITHUB_PATH is not set}"

if [[ ! "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
  # Only an immutable revision names one prerelease. The action's condition
  # already requires the full SHA, so this is defence in depth.
  echo "::notice::setup-reprobuild: '${pin}' is not a full commit SHA; not looking for a pin prerelease"
  exit 0
fi

repo="${REPRO_PIN_RELEASE_REPO:-metacraft-labs/metacraft-github-actions}"
tag="pin-${pin}"
install_dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/reprobuild-pin-release"

echo "setup-reprobuild: looking for the pin prerelease ${repo}@${tag}"
output="$(REPRO_REPO="${repo}" REPRO_RELEASE_TAG="${tag}" \
  REPRO_VERSION="${EXPECTED_VERSION:-}" REPRO_REQUIRE_CHECKSUM=true \
  REPRO_INSTALL_DIR="${install_dir}" \
  bash "${script_dir}/install-release.sh")"
rc=$?

case "${rc}" in
  0)
    bin_dir=""
    while IFS= read -r line; do
      case "${line}" in
        REPRO_BIN_DIR=*) bin_dir="${line#REPRO_BIN_DIR=}" ;;
      esac
    done <<< "${output}"
    if [ -z "${bin_dir}" ]; then
      echo "::error::setup-reprobuild: install-release.sh reported success for ${tag} but named no bin directory"
      exit 1
    fi
    echo "bin-dir=${bin_dir}" >> "${GITHUB_OUTPUT}"
    echo "${bin_dir}" >> "${GITHUB_PATH}"
    echo "setup-reprobuild: installed the pin prerelease ${repo}@${tag}"
    ;;
  3)
    # install-release.sh printed which it was (no release, no archive for
    # this platform) on stderr.
    echo "::notice::setup-reprobuild: no pin prerelease ${repo}@${tag} for this platform; building repro from source"
    ;;
  *)
    echo "::error::setup-reprobuild: the pin prerelease ${repo}@${tag} failed verification or installation (exit ${rc}). Not falling back to a source build -- see the error above."
    exit 1
    ;;
esac
