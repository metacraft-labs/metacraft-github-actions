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
#   * The credential is a Git credential helper
#     (../git-auth/git-credential-job-token.sh) that reads the job's current
#     token from a file in `$MCL_JOB_CREDENTIALS_DIR` whenever Git asks, so no
#     URL anywhere carries it: not in argv, not in `.git/config`, not in error
#     text. Git asks only when GitHub challenges a request with 401, so a
#     public repository is fetched without it.
#   * It is configured as `credential.<url>.helper` with `<url>` =
#     `https://github.com/<owner>/`. Git selects `credential.<url>.*` by scheme
#     + host + port + slash-delimited path prefix, so this answers for
#     `https://github.com/<owner>/anything` and NOT for
#     `https://github.com/OtherOrg/x`, `https://github.com/<owner>-evil/x`, or
#     `https://github.com/` itself. (Contract-tested; see the suite.)
#   * It is exported through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/
#     `GIT_CONFIG_VALUE_n` via `$GITHUB_ENV`, which is job-scoped. Nothing is
#     written to `$HOME/.gitconfig`, so nothing survives the job, and the token
#     file lives under `$RUNNER_TEMP`, which the runner empties between jobs.
#
# The token is read when Git needs it, not frozen when this step ran: the job
# credential broker and refresh-build-auth replace the file in place, so a Git
# process started after a rotation, in any later step or under a daemon a step
# started, is handed the new token. (It used to be an `http.<url>.extraHeader`
# in `GIT_CONFIG_*`, which a step cannot change once it has started, and Git
# failed an hour after the token it held was minted.) The design is described
# in ../git-auth/scoped-git-auth.sh, "THE JOB-SCOPED CREDENTIAL".
#
# The URL-scheme rewrites stay global, because they must apply to `.gitmodules`
# URLs that git reads before any of this runs — but they now rewrite to a
# CREDENTIAL-FREE `https://github.com/`, so a persisted copy is inert.
#
# CROSS-ORG PRIVATE CLONES. Anything private outside `token-owner` used to work
# by accident, off the catch-all. That path is preserved deliberately and
# explicitly: pass the repository (or owner) prefix in
# `EXTRA_TOKEN_URL_PREFIXES` and the same helper is installed for it. It is now
# a declaration rather than a side effect, which is the point — a per-repo
# minted secret should say which repo it is for.
#
# THE SCOPE ITSELF LIVES IN ../git-auth/scoped-git-auth.sh, because this was
# only two-thirds of the fix: `clone-siblings` and `clone-repo` carried the same
# URL-embedded catch-all and were not covered by the change that wrote this
# comment. They are now, and they derive the scope from the same file, so the
# next person cannot fix one copy and miss two.
#
# Environment:
#   GH_TOKEN                  (required) the token to install. While the job
#                             credential broker owns the Git token file
#                             (setup-dev-env `app-id`, `git-access: read`),
#                             the broker's token is kept instead.
#   MCL_JOB_CREDENTIALS_DIR   the job's private credential directory, which
#                             setup-nix's Nix step or the broker created; one
#                             is created under RUNNER_TEMP when it is unset.
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
# consumes and replaces with `***` rather than echoing. The token itself is
# written only to `$MCL_JOB_CREDENTIALS_DIR/git-token` (mode 600).
#
# Contract suite: ./configure-git-auth-test.sh (pure bash + real git).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "$HERE/../git-auth/scoped-git-auth.sh"

: "${GH_TOKEN:?configure-git-auth: GH_TOKEN is required}"
TOKEN_OWNERS="${TOKEN_OWNERS:-metacraft-labs}"
EXTRA_TOKEN_URL_PREFIXES="${EXTRA_TOKEN_URL_PREFIXES:-}"

# --- 1. credential-free URL-scheme rewrites -------------------------------
#
# `.gitmodules` in this org's repos spells submodule URLs in all three styles,
# and these rewrites are what makes the ssh spellings reachable by an https
# credential.
#
# They are written to `--global` here rather than carried in the process-scoped
# configuration below because they must apply to every git in the job whether or
# not it inherited this step's environment, and they carry no credential, so a
# copy that outlives the job is inert. (`clone-siblings` and `clone-repo` take
# the same rewrites through the process environment instead — they are one step,
# not a job-wide contract, and they should leave nothing behind at all.)
#
# NOTE ON NIX. This comment used to claim "Nix's internal git fetcher does not
# read gitconfig at all", offered as the reason `clone-repo` rewrites
# `.gitmodules` on disk. That has been false since Nix 2.20.0: libgit2 fetching
# was reverted in 8d422c2f (2024-01-18, "libgit2 is not capable of using
# git-credentials helpers yet"), and `src/libfetchers/git-utils.cc` has shelled
# out to the `git` binary ever since — so a Nix fetch is a `git fetch` and
# inherits `GIT_CONFIG_COUNT`, `insteadOf`, `extraHeader` and the rest.
#
# The real, narrower reason `clone-repo` still normalises `.gitmodules` is that
# Nix resolves a submodule's URL with libgit2's `git_submodule_resolve_url`,
# which handles relative URLs and does NOT apply `insteadOf`; a scp-style
# `git@github.com:owner/repo` therefore never becomes a URL Nix can hand to the
# `git` binary in the first place.
#
# The distinction matters more than the fix: "Nix ignores gitconfig" would mean
# the credential scoping in this file does not reach Nix at all, and someone
# reasoning from it would conclude they need a broader mechanism — a netrc, or a
# catch-all — to authenticate Nix's fetches. They do not. A false comment about
# credential scope is how the next person reasons their way into a real hole.
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
# Derived by ../git-auth/scoped-git-auth.sh: the scopes are
# `https://github.com/<owner>/` per declared owner plus any explicitly declared
# extra prefix. `SCOPED_GIT_AUTH_MASK=1` makes it print the derived Basic blob
# once, and only as the payload of `::add-mask::`, which the runner consumes
# and replaces with `***`: a step-local clone in a later step builds the same
# blob from the same token.
#
# `SCOPED_GIT_AUTH_REWRITES` is left off: the scheme rewrites are written to
# `--global` in section 1 above, and emitting them here as well would put a
# second copy into every step's environment for no gain.
SCOPED_GIT_AUTH_MASK=1 scoped_git_auth_build || exit $?

# --- 4. the token file and the process-scoped git configuration -----------
#
# scoped_git_auth_emit writes GH_TOKEN to `$MCL_JOB_CREDENTIALS_DIR/git-token`
# (atomically, and not while the broker owns it), and appends, per scope, the
# three entries described in scoped-git-auth.sh: an empty
# `http.<scope>.extraHeader` (no preemptive header for the scope, including
# the one `actions/checkout` persists for all of github.com), an empty
# `credential.<scope>.helper` (no inherited helper answers for the scope) and
# the helper itself. Nothing else is forced on every step.
#
# The helper reset is scoped, and that is why it is acceptable here when a
# global `credential.helper=` reset was not: it clears helpers only for the
# URLs this job's own credential covers, so a consumer that authenticates
# some other host or owner through `gh auth setup-git` or a helper of its own
# keeps it.
scoped_git_auth_emit "${GITHUB_ENV:-}" || exit $?
scoped_git_auth_report
