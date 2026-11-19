#!/usr/bin/env bash
#
# bind-repro-package.sh — use a caller-built Reprobuild Nix package as this
# job's `repro`, instead of installing a release or building from source.
#
# A workflow that builds `github:metacraft-labs/reprobuild/<pin>#reprobuild`
# itself (to record its derivation, source and image identities) already holds
# the engine. Building it again from source here costs 20-40 minutes and yields
# a second, unreceipted engine. This script admits the caller's package, and
# only that package:
#
#   - repro-build-pin must be a full lowercase commit SHA, so the package is
#     tied to an immutable revision rather than a branch or tag;
#   - REPRO_PACKAGE must be a valid path in the local Nix store;
#   - it must equal the `reprobuild` package output that the pinned flake
#     evaluates to on this system (`nix eval`, no build), so a path of another
#     revision, another system or another package is refused;
#   - it must carry the CLI and the Nix daemon helper the tool resolver starts.
#
# The package's wrapper sets every runtime default the CLI needs (see
# reprobuild nix/pkgs/by-name/re/reprobuild/package.nix), so no build shell
# variables are exported beyond the helper the source route exports too.
#
# Inputs (environment): REPRO_PACKAGE, REPRO_BUILD_PIN, optional GH_TOKEN (for
# the flake's private inputs; handed to nix through NIX_CONFIG, never argv),
# RUNNER_OS, GITHUB_OUTPUT, GITHUB_PATH, GITHUB_ENV.
# Outputs: `bin-dir=<package>/bin`.
set -euo pipefail

fail() {
  echo "::error::setup-reprobuild: $*" >&2
  exit 1
}

package="${REPRO_PACKAGE:-}"
pin="${REPRO_BUILD_PIN:-}"

if [ "${RUNNER_OS:-}" = Windows ]; then
  fail "repro-package names a Nix store path; Windows legs build repro from source"
fi
case "$package" in
  /*) ;;
  *) fail "repro-package must be an absolute Nix store path" ;;
esac
case "$package" in
  */|*[[:space:]]*) fail "repro-package must be a single store path without whitespace or a trailing slash" ;;
esac
if [[ ! "$pin" =~ ^[0-9a-f]{40}$ ]]; then
  fail "repro-package requires repro-build-pin to be a full lowercase commit SHA (got '${pin}')"
fi
command -v nix >/dev/null 2>&1 || fail "repro-package needs nix on PATH"

if [ -n "${GH_TOKEN:-}" ]; then
  newline=$'\n'
  NIX_CONFIG="${NIX_CONFIG:+${NIX_CONFIG}${newline}}access-tokens = github.com=${GH_TOKEN}"
  export NIX_CONFIG
fi

nix path-info -- "$package" >/dev/null || fail "repro-package ${package} is not a valid Nix store path"

flake="github:metacraft-labs/reprobuild/${pin}"
expected="$(nix eval --raw --no-update-lock-file "${flake}#reprobuild.outPath")" \
  || fail "could not evaluate ${flake}#reprobuild"
if [ "$expected" != "$package" ]; then
  fail "repro-package ${package} is not ${flake}#reprobuild on this system (${expected})"
fi

for executable in bin/repro libexec/reprobuild-nix-daemon; do
  [ -x "${package}/${executable}" ] || fail "repro-package ${package} has no executable ${executable}"
done

echo "setup-reprobuild: using the caller's ${flake}#reprobuild package ${package}"
"${package}/bin/repro" --version

echo "REPROBUILD_NIX_DAEMON_BIN=${package}/libexec/reprobuild-nix-daemon" >> "$GITHUB_ENV"
echo "${package}/bin" >> "$GITHUB_PATH"
echo "bin-dir=${package}/bin" >> "$GITHUB_OUTPUT"
