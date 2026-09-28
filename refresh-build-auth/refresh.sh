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
if command -v nix >/dev/null 2>&1; then
	python3 "$auth_dir/refresh-nix.py"
fi
