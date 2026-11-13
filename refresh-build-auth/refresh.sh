#!/usr/bin/env bash
# Replace setup-dev-env's job authentication without writing user config files.
set -euo pipefail
auth_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GH_TOKEN:?fresh GitHub token required}"
: "${GITHUB_ENV:?GitHub job environment file required}"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "$auth_dir/../git-auth/scoped-git-auth.sh"
TOKEN_OWNERS="${TOKEN_OWNERS:-metacraft-labs}"
SCOPED_GIT_AUTH_MASK=1 scoped_git_auth_build
scoped_git_auth_emit "$GITHUB_ENV"
scoped_git_auth_report

# Windows's DIY toolchain has no Nix. POSIX uses the existing Nix settings,
# preserving every other host's token and unrelated configuration. Appending
# extra-access-tokens would keep the OLD token: Nix's map uses the first value.
#
# The Nix refresh runs on the Node runtime the action's "Bind declared Nix-auth
# Node runtime" step exports, so it needs no interpreter from the runner's
# PATH. It used to go through a Python shim that only re-executed that same
# Node, which put an ambient python3 back on the path: the self-hosted bench
# runners have none, and the step died with "python3: command not found"
# (codetracer-ci PR #93, job 131538166833). Validate the binding here instead,
# the same way the shim did: an absolute path to an executable, nothing found
# by PATH lookup.
if command -v nix >/dev/null 2>&1; then
  node="${GHA_NIX_AUTH_NODE:-}"
  if [[ $node != /* || ! -f $node || ! -x $node ]]; then
    echo "refresh-build-auth: GHA_NIX_AUTH_NODE must name the declared Actions Node runtime as an absolute path to an executable (got '${node}')" >&2
    exit 1
  fi
  "$node" "$auth_dir/nix-auth.cjs"
fi
