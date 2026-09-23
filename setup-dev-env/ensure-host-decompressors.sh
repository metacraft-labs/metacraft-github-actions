#!/usr/bin/env bash
#
# ensure-host-decompressors.sh — make the host archive tools `repro` shells
# out to available on PATH, or fail up front naming the ones that are not.
#
# WHY
# ---
# When a tool a project declares under `uses:` is not already on PATH, `repro`
# provisions it from a release tarball. It checks that a host `tar` exists and
# then runs `tar -tzf` / `-tJf` / `-tjf` — and GNU tar runs `gzip` / `xz` /
# `bzip2` as a CHILD PROCESS to do the decompression. Nothing checks for those.
#
# On the self-hosted runners, setup-nix puts a Nix profile at the front of
# PATH that carries none of them, so a job gets as far as `repro build`, spends
# its time resolving tools, and then dies with
#
#     tar (child): xz: Cannot exec: No such file or directory
#
# twice (once per tar invocation `repro` tries) — a message that names a
# decompressor, arrives long after setup has reported success, and points at
# nothing the job's author wrote. `sed` failed the same way in the installer
# until it stopped trusting PATH; this is the same class, one layer further in.
#
# WHAT IT DOES
# ------------
# For each of tar, gzip, xz and bzip2:
#   * present on PATH                   -> nothing to do;
#   * missing, and `nix` is available   -> build it from nixpkgs and append its
#                                          `bin/` to $GITHUB_PATH, then CHECK
#                                          the tool is actually reachable;
#   * missing, and it cannot be provided -> fail, naming every missing tool.
#
# Success from `nix build` is not taken as evidence. A build that succeeds and
# yields an output with no `bin/<tool>` would otherwise print "provided" and
# leave the job to fail exactly as before, just later.
#
# This script calls no external command other than `nix`, so it cannot itself
# be broken by the PATH it is repairing.
#
# Inputs (environment):
#   GITHUB_PATH                  file GitHub reads to extend PATH (required)
#   ENSURE_HOST_TOOLS_NIX        nix executable to use (default: `nix` on PATH)
#   ENSURE_HOST_TOOLS_NIXPKGS    flake ref to build from (default: `nixpkgs`)
set -uo pipefail

: "${GITHUB_PATH:?ensure-host-decompressors: GITHUB_PATH is not set}"
NIXPKGS="${ENSURE_HOST_TOOLS_NIXPKGS:-nixpkgs}"

# tool:nixpkgs-attribute
TOOLS=("tar:gnutar" "gzip:gzip" "xz:xz" "bzip2:bzip2")

missing=()
for entry in "${TOOLS[@]}"; do
  tool="${entry%%:*}"
  if command -v "${tool}" >/dev/null 2>&1; then
    echo "ensure-host-decompressors: ${tool} present at $(command -v "${tool}")"
  else
    missing+=("${entry}")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "ensure-host-decompressors: every archive tool repro shells out to is on PATH"
  exit 0
fi

NIX="${ENSURE_HOST_TOOLS_NIX:-}"
if [ -z "${NIX}" ]; then
  NIX="$(command -v nix 2>/dev/null || true)"
fi

for entry in "${missing[@]}"; do
  tool="${entry%%:*}"
  attr="${entry#*:}"
  if [ -z "${NIX}" ]; then
    continue
  fi
  echo "ensure-host-decompressors: ${tool} is not on PATH; building ${NIXPKGS}#${attr}"
  if ! out="$("${NIX}" build --no-link --print-out-paths "${NIXPKGS}#${attr}" 2>&1)"; then
    echo "ensure-host-decompressors: nix build ${NIXPKGS}#${attr} failed:" >&2
    echo "${out}" >&2
    continue
  fi
  # A package may print several output paths; the tool lives in whichever
  # carries `bin/<tool>`.
  while IFS= read -r p; do
    if [ -n "${p}" ] && [ -x "${p}/bin/${tool}" ]; then
      echo "${p}/bin" >>"${GITHUB_PATH}"
      PATH="${p}/bin:${PATH}"
      echo "ensure-host-decompressors: ${tool} provided from ${p}/bin"
      break
    fi
  done <<<"${out}"
done

still=()
for entry in "${missing[@]}"; do
  tool="${entry%%:*}"
  command -v "${tool}" >/dev/null 2>&1 || still+=("${tool}")
done

if [ "${#still[@]}" -gt 0 ]; then
  echo "::error::ensure-host-decompressors: not on PATH and could not be provided: ${still[*]}. repro provisions tools from tarballs with the host tar, which runs these as child processes; without them a later 'repro build' fails with 'tar (child): <tool>: Cannot exec'. Put them on the runner's PATH, or make nix available to this step."
  exit 1
fi

echo "ensure-host-decompressors: every archive tool repro shells out to is now on PATH"
exit 0
