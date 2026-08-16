#!/usr/bin/env bash
#
# configure-git-auth.sh — install the Git-CLI credential for the org's own
# GitHub repositories, scoped to those repositories and to this job.
#
# WHAT THIS REPLACES, AND WHY
# ---------------------------
# `setup-nix` used to authenticate the Git CLI with a single global catch-all
# rewrite:
#
#     git config --global \
#       url."https://x-access-token:$TOKEN@github.com/".insteadOf \
#       "https://github.com/"
#
# That is three separate problems, none of them "the token reaches a host it
# shouldn't" — every URL it rewrites is a github.com URL, and github.com issued
# the token. The problems are:
#
#   1. PERSISTENCE. `--global` writes `$HOME/.gitconfig`. Self-hosted runners in
#      this org reuse workspaces AND home directories, so a live App token
#      outlives the job that minted it and is inherited by whatever runs next on
#      that machine — a different repo's workflow, or a fork PR.
#
#   2. THE TOKEN ENDS UP IN URLs. A rewritten URL is passed to
#      `git-remote-https` as an argv element (readable in /proc on a shared
#      runner), is written verbatim into the `.git/config` of every clone the
#      rewrite touches, and is echoed by git's own "unable to access
#      'https://x-access-token:...@github.com/...'" failure messages.
#
#   3. BREADTH. It attaches to fetches of third-party repos — nixpkgs,
#      `status-im/*`, `nim-lang/*`, and any transitive git dependency a build
#      tool resolves — so problem 2's on-disk copies land inside dependency
#      trees that get cached and uploaded as artifacts.
#
# The replacement fixes all three:
#
#   * The credential is an `http.<url>.extraHeader`, so no URL anywhere carries
#     it: not in argv, not in `.git/config`, not in error text.
#   * `<url>` is `https://github.com/<owner>/`. Git matches `http.<url>.*` by
#     scheme + host + port + slash-delimited path prefix, so this matches
#     `https://github.com/<owner>/anything` and does NOT match
#     `https://github.com/OtherOrg/x`, `https://github.com/<owner>-evil/x`, or
#     `https://github.com/` itself. (Contract-tested; see the suite.)
#   * It is exported through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/
#     `GIT_CONFIG_VALUE_n` via `$GITHUB_ENV`, which is job-scoped. Nothing is
#     written to `$HOME/.gitconfig`, so nothing survives the job.
#
# The URL-scheme rewrites stay global, because they must apply to `.gitmodules`
# URLs that git reads before any of this runs — but they now rewrite to a
# CREDENTIAL-FREE `https://github.com/`, so a persisted copy is inert.
#
# CROSS-ORG PRIVATE CLONES. Anything private outside `token-owner` used to work
# by accident, off the catch-all. That path is preserved deliberately and
# explicitly: pass the repository (or owner) prefix in
# `EXTRA_TOKEN_URL_PREFIXES` and the same header is installed for it. It is now
# a declaration rather than a side effect, which is the point — a per-repo
# minted secret should say which repo it is for.
#
# Environment:
#   GH_TOKEN                  (required) the token to install.
#   TOKEN_OWNERS              whitespace/newline-separated GitHub owners the
#                             token is scoped to. Default: metacraft-labs.
#   EXTRA_TOKEN_URL_PREFIXES  whitespace/newline-separated extra https URL
#                             prefixes to cover (e.g. a single private repo in
#                             another org). Optional.
#   GITHUB_ENV                (optional) file to append the process-scoped git
#                             configuration to. When unset, the same assignments
#                             are written to stdout in `KEY=VALUE` form so this
#                             script is runnable and testable outside Actions.
#
# This script NEVER prints $GH_TOKEN, and prints the derived Authorization
# blob only inside a `::add-mask::` workflow command, whose payload the runner
# consumes and replaces with `***` rather than echoing.
#
# Contract suite: ./configure-git-auth-test.sh (pure bash + real git).
set -euo pipefail

: "${GH_TOKEN:?configure-git-auth: GH_TOKEN is required}"
TOKEN_OWNERS="${TOKEN_OWNERS:-metacraft-labs}"
EXTRA_TOKEN_URL_PREFIXES="${EXTRA_TOKEN_URL_PREFIXES:-}"

# --- 1. credential-free URL-scheme rewrites -------------------------------
#
# `.gitmodules` in this org's repos spells submodule URLs in all three styles.
# Nix's internal git fetcher does not read gitconfig at all, which is why
# `clone-repo` additionally rewrites `.gitmodules` on disk; these rewrites cover
# the git CLI.
#
# `insteadOf` is multi-valued and both values must survive, so each is written
# with `--replace-all` plus a VALUE-PATTERN matching only itself: that makes a
# re-run on a reused home directory idempotent (it rewrites its own line) while
# leaving the sibling value alone. A bare `--replace-all` would drop whichever
# was written first.
git config --global --replace-all url."https://github.com/".insteadOf \
	"git@github.com:" '^git@github\.com:$'
git config --global --replace-all url."https://github.com/".insteadOf \
	"ssh://git@github.com/" '^ssh://git@github\.com/$'

# --- 2. evict any credential-bearing rewrite left by an earlier job --------
#
# A runner whose $HOME predates this change still has
# `url.https://x-access-token:<stale token>@github.com/.insteadOf` in
# `~/.gitconfig`. Leaving it would defeat every line above: it still matches
# `https://github.com/` and still injects a credential into the URL. It is also,
# on its own terms, a stale secret sitting in a file, so remove it whether or
# not this run installs a replacement.
#
# `--get-regexp` exits 1 when nothing matches; that is not an error here.
while IFS= read -r _key; do
	[[ -z $_key ]] && continue
	case "$_key" in
	url.*x-access-token*) ;;
	*) continue ;;
	esac
	git config --global --unset-all "$_key" 2>/dev/null || true
	# `--unset-all` empties the value list but leaves the (now empty) subsection
	# behind; `--remove-section` clears it so a later `--get-regexp` is quiet.
	git config --global --remove-section "${_key%.insteadOf}" 2>/dev/null || true
done < <(
	{ git config --global --get-regexp '^url\..*\.insteadOf$' 2>/dev/null || true; } |
		while IFS= read -r _line; do printf '%s\n' "${_line%% *}"; done
)

# --- 3. the scoped credential --------------------------------------------
#
# Basic auth with the App token as the password, which is what
# `x-access-token:<token>@` encoded positionally in the URL. Same credential,
# carried in a header instead of a URL.
AUTH_BASIC="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\r\n')"
printf '::add-mask::%s\n' "$AUTH_BASIC"

# Collect the URL prefixes this credential covers. Owners become
# `https://github.com/<owner>/`.
#
# The trailing slash is for readability only, and it is worth being exact about
# why: git's own path match breaks on `/`, so `https://github.com/<owner>`
# already fails to match `https://github.com/<owner>-evil/x`. The boundary is
# git's, not ours — do not "harden" it here with a manual check, and do not
# assume dropping the slash would open it.
declare -a SCOPES=()
for _owner in $TOKEN_OWNERS; do
	[[ -z $_owner ]] && continue
	SCOPES+=("https://github.com/${_owner}/")
done
for _prefix in $EXTRA_TOKEN_URL_PREFIXES; do
	[[ -z $_prefix ]] && continue
	case "$_prefix" in
	https://*) ;;
	*)
		echo "configure-git-auth: extra-token-url-prefixes entry '$_prefix' is not an https:// URL" >&2
		exit 2
		;;
	esac
	SCOPES+=("$_prefix")
done
if [[ ${#SCOPES[@]} -eq 0 ]]; then
	echo "configure-git-auth: no token scope (token-owner and extra-token-url-prefixes are both empty)" >&2
	exit 2
fi

# --- 4. emit as process-scoped git configuration --------------------------
#
# One numbered pair per scope, and NOTHING else that constrains git.
#
# A `credential.helper=` reset belongs here on the merits — it would stop a
# reused runner's leftover `~/.git-credentials` from authenticating a fetch this
# scope deliberately left bare — and it is deliberately NOT included. Emitting
# it through `$GITHUB_ENV` applies it to every step of every job in the org, and
# it would silently break any consumer that authenticates git through `gh auth
# setup-git` or a helper of its own. That is someone else's credential, not the
# one this action installs, so disabling it is out of scope for a change whose
# whole claim is that it regresses nothing.
_emit() {
	if [[ -n ${GITHUB_ENV:-} ]]; then
		printf '%s\n' "$1" >>"$GITHUB_ENV"
	else
		printf '%s\n' "$1"
	fi
}

_n=0
for _scope in "${SCOPES[@]}"; do
	_emit "GIT_CONFIG_KEY_${_n}=http.${_scope}.extraHeader"
	_emit "GIT_CONFIG_VALUE_${_n}=AUTHORIZATION: basic ${AUTH_BASIC}"
	_n=$((_n + 1))
done
_emit "GIT_CONFIG_COUNT=${_n}"
# Without a URL-embedded credential a misconfigured scope would block on a
# prompt instead of failing; make it fail.
_emit "GIT_TERMINAL_PROMPT=0"

echo "configure-git-auth: git credential scoped to ${#SCOPES[@]} URL prefix(es):"
for _scope in "${SCOPES[@]}"; do
	echo "  ${_scope}"
done
