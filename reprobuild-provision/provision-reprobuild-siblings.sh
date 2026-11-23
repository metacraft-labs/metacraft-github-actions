#!/usr/bin/env bash
#
# provision-reprobuild-siblings.sh -- clone the sibling repositories the `repro`
# CLI build depends on, next to the host checkout, WITH the CI credential
# actually attached to every request.
#
# WHY THIS FILE EXISTS: A CREDENTIAL IN A URL IS NOT SENT TO A PUBLIC REPO
# -----------------------------------------------------------------------
# This step used to clone with the credential positioned in the URL:
#
#     git clone --depth 1 --branch "$ref" --single-branch \
#       "https://x-access-token:${GH_TOKEN}@github.com/metacraft-labs/${name}.git" ...
#
# which reads as authenticated and is not. Git does NOT preemptively send a
# URL's userinfo. It issues the first `GET /<repo>/info/refs?service=...`
# ANONYMOUSLY and attaches `Authorization` only after the server answers 401.
#
#   - A PRIVATE repo answers 401, so git retries with the credential and the
#     clone is authenticated. This is why the shape looked fine for years.
#   - A PUBLIC repo answers 200 on that first request. There is no challenge,
#     so git never sends the credential, and the ENTIRE clone is anonymous --
#     silently, with a token sitting right there in the URL.
#
# Observed directly with `GIT_TRACE_CURL=1` against these very repositories: a
# clone of the public `metacraft-labs/runquota` with a URL credential sends no
# `Authorization` header on any request, and succeeds even when the token in the
# URL is complete nonsense. The token was never read by anything.
#
# That is not a cosmetic difference, because anonymous github.com traffic is
# rate-limited PER IP and this org's ephemeral-runner fleet egresses from one
# address. The whole fleet shares one anonymous budget, so the clone fails with
#
#     fatal: remote error: GitHub is temporarily limiting some unauthenticated
#     downloads to protect the stability of the platform. Please retry later or
#     authenticate.
#     -> exit 128
#
# under ordinary load. `setup-reprobuild` already carries this reasoning for its
# `api.github.com` lookups ("Anonymous API access is 60 requests/hour PER IP and
# the whole ephemeral-runner fleet egresses from one address"); the git clones on
# this path were simply never migrated with it.
#
# THE FIX is the same one the rest of this repository already uses: a
# credential-FREE URL plus an owner-scoped `http.<url>.extraHeader` in
# process-scoped git configuration. An `extraHeader` is attached to EVERY
# request including the first, so it does not depend on being challenged, and a
# public repo is therefore fetched authenticated. See ../git-auth/ for the
# mechanism, and `authenticated-clone.sh` for the loud failure diagnostics this
# step gets for free by going through it.
#
# WHY THE FAILURE WAS ILLEGIBLE, WHICH IS HALF THE DEFECT
# -------------------------------------------------------
# The old body was a bare `git clone` inside a `for` loop under `set -e`. When
# the second repository in the list died, the log showed the rate-limit line and
# `Process completed with exit code 128` -- and nothing that said WHICH entry,
# which owner, which ref, or that the token had been ignored rather than
# rejected. Going through `authenticated-clone.sh` names the repository and
# prints git's own output; the preflight below names the ref before any clone
# starts.
#
# THE REFS, AND WHY THEY ARE NOT `main`
# -------------------------------------
# Every entry here was pinned to `main`. NONE of these repositories has a `main`
# branch -- the org renamed its mainlines (this actions repo went `main` -> `dev`
# itself; see `setup-dev-env: resolve own actions at @dev after the main->dev
# rename`) and this list was not carried along. Verified against the remotes:
#
#     runquota             main: absent   mainline: dev
#     nim-stackable-hooks  main: absent   mainline: stable
#     io-mon               main: absent   mainline: stable
#     codetracer           main: absent   mainline: stable
#
# On the Windows path this was invisible: `clone_repo` retried without
# `--branch` on any failure, so every one of these had been silently resolving
# to the default branch instead of the ref it named. On the Linux/macOS path
# there was no retry, so it was a hard failure -- masked only because the
# anonymous-clone defect above killed the step first. Fixing the credential
# without fixing the refs would have moved the error, not removed it.
#
# Those named mainlines are now only the FALLBACK. A source build names the
# reprobuild checkout it builds, and each sibling is then cloned at the
# revision that checkout's `flake.lock` records (see "WHICH REVISION OF EACH
# SIBLING" below). A named mainline remains for a sibling that lock does not
# pin and for a caller that names no reprobuild checkout; "whatever the default
# branch is today" would be no pin at all, which is the thing this org's
# sibling-resolution contract exists to prevent.
set -uo pipefail

# This script's directory, by parameter expansion rather than `dirname`: the
# step runs before any toolchain is installed, and on the self-hosted macOS
# runners its PATH carries bash and git but no coreutils.
HERE="${BASH_SOURCE[0]%/*}"
[ "${HERE}" != "${BASH_SOURCE[0]}" ] || HERE="."

# shellcheck source=../ci-roots/route.sh
. "${GITHUB_ACTION_PATH:-${HERE}}/../ci-roots/route.sh" || exit 1

# shellcheck source=flake-lock-revisions.sh
. "${GITHUB_ACTION_PATH:-${HERE}}/flake-lock-revisions.sh" || exit 1

GIT_AUTH_DIR="${GIT_AUTH_DIR:-${HERE}/../git-auth}"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "${GIT_AUTH_DIR}/scoped-git-auth.sh"

# `//\\//` -- normalise the Windows separator, exactly as `clone-siblings.sh`
# does: this script runs under bash on the Windows runners too, where
# $GITHUB_WORKSPACE arrives backslashed.
WS="${MCL_WORKSPACE_ROOT//\\//}"
# `SIBLING_OWNER` may be a whitespace-separated list: `setup-dev-env` passes
# its `token-owner` here, and that input accepts several owners (for example
# `metacraft-labs aiken-lang`). The list is kept whole for the credential scope
# (`TOKEN_OWNERS` below); the siblings are cloned from its FIRST word, exactly as
# `clone-siblings.sh` takes its default owner. Using the list verbatim built
# `metacraft-labs aiken-lang/runquota` as a repository name, and every source
# build of a multi-owner caller failed its preflight.
# First word only; see the `sibling-owner` input description.
CLONE_OWNER=""
for _w in ${SIBLING_OWNER:-}; do
  CLONE_OWNER="${_w}"
  break
done
# Unset, empty and whitespace-only all mean the documented default. Without
# this, a whitespace-only value would yield an EMPTY owner and clone
# `/runquota`.
if [ -z "${CLONE_OWNER}" ]; then
  CLONE_OWNER="metacraft-labs"
  SIBLING_OWNER="metacraft-labs"
fi
# ---------------------------------------------------------------------------
# WHICH REVISION OF EACH SIBLING: the one the reprobuild being built locks.
# ---------------------------------------------------------------------------
#
# A source build at `repro-build-pin` must build that revision as its own
# `flake.lock` describes it -- the dependency set its release package (the Nix
# build of the same flake) was built from. This file used to clone every
# sibling at a named mainline (`runquota@dev`, `io-mon@dev`, ...) whatever
# reprobuild revision was being built, so a release cut from a reprobuild that
# needed RunQuota work not yet promoted to `dev` could not be rebuilt from
# source at all: reprobuild v0.2.26 (`b9cf09b07`) locks `runquota-src` at an
# `agents` commit, `runquota@dev` lacked `runquota_client/pressure_text`, and
# the build stopped at `cannot open file`. Every consumer then had to carry a
# RunQuota pin that moved in lock-step with its `repro-build-pin`.
#
# So when the caller names the reprobuild checkout being built
# (`REPROBUILD_SOURCE_DIRECTORY`, which `setup-reprobuild` always passes), each
# sibling defaults to the revision that checkout's `flake.lock` records for the
# root input of the same repository name. An explicit caller input
# (`runquota-ref`, `io-mon-ref`, `stackable-hooks-pin`,
# `test-certificates-tools-ref`) still wins: selecting a different revision is
# the caller's explicit choice, never the default. A sibling the lock does not
# pin, or a caller that names no reprobuild checkout (a standalone use of this
# action), keeps the built-in default below. A named checkout without a
# readable lock is a refusal, not a fallback.
REPROBUILD_SOURCE_DIRECTORY="${REPROBUILD_SOURCE_DIRECTORY:-}"
REPROBUILD_SOURCE_DIRECTORY="${REPROBUILD_SOURCE_DIRECTORY//\\//}"
LOCKED_REVS=""
if [ -n "${REPROBUILD_SOURCE_DIRECTORY}" ]; then
  reprobuild_lock="${REPROBUILD_SOURCE_DIRECTORY}/flake.lock"
  if [ ! -f "${reprobuild_lock}" ]; then
    echo "::error::reprobuild-provision: reprobuild-source-directory '${REPROBUILD_SOURCE_DIRECTORY}' has no flake.lock, so the sibling revisions that reprobuild locks cannot be read. Refusing to guess a branch tip." >&2
    exit 1
  fi
  # One `<repository> <owner> <40-hex rev>` line per repository a root input
  # locks to a git forge source, lower-cased. Inputs of other kinds, and
  # `follows` entries, are skipped. Inputs are matched by repository
  # coordinates, never by input alias. Read with bash builtins only: this step
  # runs before any toolchain is installed, on runners whose PATH has neither
  # python3 nor coreutils (see flake-lock-revisions.sh).
  LOCKED_REVS="$(flake_lock_revisions "${reprobuild_lock}")" || {
    echo "::error::reprobuild-provision: could not read sibling revisions from ${reprobuild_lock} (see the message above)." >&2
    exit 1
  }
  echo "reprobuild-provision: sibling revisions locked by ${reprobuild_lock}:"
  while IFS= read -r _line; do
    [ -n "${_line}" ] && echo "    ${_line}"
  done <<<"${LOCKED_REVS}"
fi

# `sibling_rev <name> <explicit> <built-in default>` -- print the revision to
# clone, and say on stderr where it came from. The lock entry for
# `<clone owner>/<name>` is preferred; otherwise every locked `*/<name>` must
# agree on one revision. Disagreement is a refusal (status 1): there is no
# single revision to clone.
CLONE_OWNER_LC="$(flake_lock_lowercase "${CLONE_OWNER}")"
# `locked_revs_of <name> [<owner>]` -- the distinct revisions LOCKED_REVS
# records for repository <name> (of <owner>, when given), one per line.
locked_revs_of() {
  local want_name="$1" want_owner="${2:-}" repo owner rev nl=$'\n' found=""
  while read -r repo owner rev; do
    [ "${repo}" = "${want_name}" ] || continue
    [ -z "${want_owner}" ] || [ "${owner}" = "${want_owner}" ] || continue
    case "${nl}${found}" in *"${nl}${rev}${nl}"*) continue ;; esac
    found+="${rev}${nl}"
  done <<<"${LOCKED_REVS}"
  printf '%s' "${found%"${nl}"}"
}
sibling_rev() {
  local name="$1" explicit="$2" fallback="$3" locked="" why="" nl=$'\n'
  if [ -n "${explicit}" ]; then
    echo "reprobuild-provision: ${name} @ ${explicit} (the caller's explicit input)" >&2
    printf '%s' "${explicit}"
    return 0
  fi
  locked="$(locked_revs_of "${name}" "${CLONE_OWNER_LC}")"
  if [ -z "${locked}" ]; then
    locked="$(locked_revs_of "${name}")"
  fi
  case "${locked}" in
    *[![:xdigit:]]*)
      echo "::error::reprobuild-provision: the reprobuild lock pins ${name} at more than one revision (${locked//${nl}/ }); there is no single revision to clone. Name one explicitly." >&2
      return 1
      ;;
  esac
  if [ -n "${locked}" ]; then
    echo "reprobuild-provision: ${name} @ ${locked} (locked by the reprobuild being built)" >&2
    printf '%s' "${locked}"
    return 0
  fi
  if [ -n "${REPROBUILD_SOURCE_DIRECTORY}" ]; then
    why="the reprobuild lock does not pin it"
  else
    why="no reprobuild-source-directory was given"
  fi
  echo "reprobuild-provision: ${name} @ ${fallback} (built-in default; ${why})" >&2
  printf '%s' "${fallback}"
}

RUNQUOTA_REF="$(sibling_rev runquota "${RUNQUOTA_REF:-}" dev)" || exit 1
IO_MON_REF="$(sibling_rev io-mon "${IO_MON_REF:-}" dev)" || exit 1
# The built-in `test-certificates-tools` default is a REVISION, not `dev`,
# because its `dev` is the wrong source: reprobuild links the
# `test_certificates` package against work on that repository's `agents`
# branch. The engine's `config.nims` puts `../test-certificates-tools/src` on
# the Nim path, so a `dev` checkout would compile (or not) against a library
# the engine never saw. This constant only serves a caller that names no
# reprobuild checkout; a source build reads the revision from the lock above.
TEST_CERTIFICATES_TOOLS_DEFAULT="a726655886808d1062390d05c50f4fce03150eb4"
TEST_CERTIFICATES_TOOLS_REF="$(sibling_rev test-certificates-tools "${TEST_CERTIFICATES_TOOLS_REF:-}" "${TEST_CERTIFICATES_TOOLS_DEFAULT}")" || exit 1
STACKABLE_HOOKS_PIN="${STACKABLE_HOOKS_PIN:-}"
if [[ -n "$STACKABLE_HOOKS_PIN" && ! "$STACKABLE_HOOKS_PIN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::stackable-hooks-pin must be a full lowercase source SHA" >&2
  exit 2
fi
STACKABLE_HOOKS_REF="$(sibling_rev nim-stackable-hooks "${STACKABLE_HOOKS_PIN}" dev)" || exit 1
# reprobuild's flake took `codetracer-native-recorder` as an input until
# reprobuild 3141282d55 ("drop a source input no derivation consumes", first
# released in v0.2.0). A source build of a reprobuild whose lock does not pin
# it has nothing to override, so the recorder is not cloned: in the default
# layout the clone lands INSIDE the consumer's checkout, where a stale copy of
# the recorder is scanned as part of whatever repository is being tested (the
# recorder's own whole-tree source scans failed on exactly that copy). A lock
# that does pin it (a pre-v0.2.0 reprobuild), or a standalone call that names
# no reprobuild checkout, keeps the clone.
CLONE_NATIVE_RECORDER=1
if [ -n "${REPROBUILD_SOURCE_DIRECTORY}" ] &&
  [ -z "$(locked_revs_of codetracer-native-recorder)" ]; then
  CLONE_NATIVE_RECORDER=0
  echo "reprobuild-provision: codetracer-native-recorder not cloned (the reprobuild being built has no such input)" >&2
else
  CODETRACER_NATIVE_RECORDER_REF="$(sibling_rev codetracer-native-recorder "" stable)" || exit 1
fi
if [ "${RUNNER_OS:-Linux}" = "Windows" ]; then
  # The Windows env.ps1 build reads these as source-only siblings. They follow
  # the reprobuild lock exactly as the flake inputs above do.
  CODETRACER_REF="$(sibling_rev codetracer "" dev)" || exit 1
  NIM_SHM_LEASE_REF="$(sibling_rev nim-shm-lease "" dev)" || exit 1
  NIM_SHM_QUEUE_REF="$(sibling_rev nim-shm-queue "" dev)" || exit 1
  NIM_SHM_GSET_REF="$(sibling_rev nim-shm-gset "" dev)" || exit 1
  REPROBUILD_TEST_ADAPTERS_REF="$(sibling_rev reprobuild-test-adapters "" dev)" || exit 1
  REPROBUILD_CT_TEST_RUNNER_REF="$(sibling_rev reprobuild-ct-test-runner "" dev)" || exit 1
  REPROBUILD_LLM_AGENT_PACKAGES_REF="$(sibling_rev reprobuild-llm-agent-packages "" dev)" || exit 1
  NIM_CLI_SPEC_REF="$(sibling_rev nim-cli-spec "" dev)" || exit 1
  NIM_ENTRYPOINTS_REF="$(sibling_rev nim-entrypoints "" dev)" || exit 1
  NIM_CONFUTILS_REF="$(sibling_rev nim-confutils "" dev)" || exit 1
fi

# A directory that is NOT inside the consumer's checkout, for the repo-aware git
# commands below to run from. See the long note in `preflight`: inside the
# checkout, `actions/checkout`'s persisted catch-all credential and this
# script's owner-scoped one BOTH match a github.com URL, and git sends two
# `Authorization` headers, which GitHub answers with 400.
NEUTRAL_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
NEUTRAL_DIR="${NEUTRAL_DIR//\\//}"
[ -d "${NEUTRAL_DIR}" ] || NEUTRAL_DIR="/"

# `scrub_token <text>` -- never let a diagnostic be the thing that prints the
# credential. `authenticated-clone.sh` carries the same guard for the same
# reason: a diagnostic path is exactly where an invariant gets discovered to be
# false, and discovering it by printing the token into a public Actions log is
# not an acceptable way to find out.
scrub_token() {
  local text="$1"
  if [ -n "${GH_TOKEN:-}" ]; then
    text="${text//${GH_TOKEN}/\*\*\*}"
  fi
  printf '%s' "${text}"
}

# ---------------------------------------------------------------------------
# The credential, scoped to the owner this step clones from.
# ---------------------------------------------------------------------------
#
# SCOPED_GIT_AUTH_REWRITES: `codetracer`'s `.gitmodules` spells its submodule
# URLs in the ssh forms, and the selective submodule update below has to reach
# them over https for the header to authenticate anything.
#
# EXTRA_TOKEN_URL_PREFIXES: the `status-im/` owner prefix, DECLARED here for
# the `status-im/nim-bearssl` clone on the Windows path and nowhere else.
#
# This file used to say that clone could not be authenticated, because the CI
# credential is a GitHub App installation token for `metacraft-labs` and
# `status-im` has no installation of that app. The premise is true; the
# conclusion was not. GitHub does not require a credential to be SCOPED to a
# repository to accept it on a PUBLIC one, only to be VALID: an installation
# token grants no private access outside its installation, and `nim-bearssl`
# needs none. Measured (metacraft-github-actions run 34273033056, job
# 102219153977) with an installation token covering nothing in `status-im`:
#
#   anonymous ls-remote of status-im/nim-bearssl            -> rc=0 (control)
#   same, installation token in a preemptive extraHeader    -> rc=0, right SHA
#   same header against the token's own repository         -> rc=0 (control)
#
# and GitHub reads the header rather than ignoring it: a fake token in the same
# header is rejected on the same public repository. An authenticated request is
# not drawn against the per-IP anonymous budget, which is the point of this
# whole file.
#
# The OWNER prefix rather than the one repository, because `nim-bearssl`'s
# `bearssl/csources` submodule is `status-im/BearSSL`, a second fetch on the
# same budget. This does NOT widen any default: `TOKEN_OWNERS` is still the
# sibling owner list (by default the one owner `metacraft-labs`), and
# `setup-nix/configure-git-auth-test.sh` still asserts that `status-im`
# receives no credential under the default scope. The declaration
# is pinned on the wire by `test-bearssl-auth.py`.
#
# Built on GIT_AUTH_URL_BASE for the same reason `authenticated-clone.sh` is: it
# is github.com in production, and the contract suite points it at a local
# authenticating git server. `scoped_git_auth_build` refuses any base that is
# not github.com or loopback.
URL_BASE="${GIT_AUTH_URL_BASE:-https://github.com/}"
# The WHOLE `SIBLING_OWNER` list, not just the clone owner: this is the same
# value `setup-nix` scopes its credential to, and `scoped_git_auth_build`
# installs one owner-scoped header per whitespace-separated word.
export TOKEN_OWNERS="${SIBLING_OWNER}"
STATUS_IM_SCOPE="${URL_BASE}status-im/"
export EXTRA_TOKEN_URL_PREFIXES="${STATUS_IM_SCOPE}"
export SCOPED_GIT_AUTH_REWRITES=1
export SCOPED_GIT_AUTH_MASK=1
scoped_git_auth_build || exit 1
scoped_git_auth_export
scoped_git_auth_report

if [ -z "${GH_TOKEN:-}" ]; then
  # Not fatal: `codetracer-native-recorder`, cloned only for a reprobuild that
  # still takes it as an input, is the only private entry, so a
  # tokenless run can still get some way in. It will however be cloning
  # anonymously, which is the exact condition this file exists to remove, so
  # it must not pass in silence.
  echo "::warning::reprobuild-provision: no 'gh-token' was supplied. Every clone below will be anonymous and subject to GitHub's per-IP unauthenticated download limit -- the failure mode this step was rewritten to eliminate. Private siblings will fail outright."
fi

# `report_submodule_failure <exit-code> <log-file>` -- say what git actually
# said when the selective codetracer submodule update fails.
#
# This used to print one fixed sentence blaming the credential's owner scope,
# with git's own stderr discarded. A transient fault (a dropped connection, a
# 5xx from the forge) was therefore reported as a credential-scope mistake and
# the real error was unrecoverable from the log. Now: a bounded tail of git's
# combined output is always printed (token-scrubbed), the failing submodule URL
# is named when git names one, and the owner-scope explanation is added ONLY
# when the evidence supports it -- an authentication/not-found error AND a
# failing URL that is neither under a `TOKEN_OWNERS` owner nor the declared extra
# prefix. No retry: a failure should be seen, not absorbed.
report_submodule_failure() {
  local rc="$1" log="$2" tail_text failing_url="" explanation _o covered
  tail_text="$(tail -n 40 "${log}")"
  # `fatal: clone of '<url>' into submodule path '<path>' failed`
  failing_url="$(sed -n "s/.*clone of '\([^']*\)' into submodule path.*/\1/p" "${log}" | head -n 1)"
  explanation="git reported the error above; it is not an authentication or owner-scope problem as far as the output shows."
  if [ -n "${failing_url}" ] \
    && grep -qiE 'Authentication failed|could not read Username|terminal prompts disabled|returned error: (403|404)|Repository not found|not found' "${log}"; then
    covered=0
    case "${failing_url}" in
      "${STATUS_IM_SCOPE}"*) covered=1 ;;
    esac
    for _o in ${TOKEN_OWNERS}; do
      case "${failing_url}" in
        *"/${_o}/"* | *":${_o}/"*) covered=1 ;;
      esac
    done
    if [ "${covered}" = 0 ]; then
      explanation="The scoped credential covers '${TOKEN_OWNERS}' (plus the declared status-im prefix) only; a submodule hosted under another owner cannot be authenticated by it."
    fi
  fi
  echo "::error::reprobuild-provision: updating codetracer's source-only Nim submodules failed (git exit ${rc}${failing_url:+, submodule URL $(scrub_token "${failing_url}")}). ${explanation}"
  echo "reprobuild-provision: last lines of git's output (at most 40):"
  scrub_token "${tail_text}"
  echo
}

# ---------------------------------------------------------------------------
# `clone <owner/name> <rev> [extra authenticated-clone.sh flags...]`
# ---------------------------------------------------------------------------
clone() {
  local repo="$1" rev="$2"
  shift 2
  local name="${repo##*/}"
  echo "reprobuild-provision: ${repo} @ ${rev} -> ${WS}/${name}"
  bash "${GIT_AUTH_DIR}/authenticated-clone.sh" \
    --repo "${repo}" --dest "${WS}/${name}" --rev "${rev}" \
    --shallow "$@" || exit 1

  # The parent directory, by parameter expansion: no `dirname` on PATH here.
  local parent_ws="${WS}"
  while [ "${parent_ws}" != "/" ] && [ "${parent_ws%/}" != "${parent_ws}" ]; do
    parent_ws="${parent_ws%/}"
  done
  parent_ws="${parent_ws%/*}"
  [ -n "${parent_ws}" ] || parent_ws="/"
  if [ "${parent_ws}" != "${WS}" ] && [ -d "${parent_ws}" ] && [ ! -e "${parent_ws}/${name}" ]; then
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(cygpath -w "${parent_ws}/${name}")' -Target '$(cygpath -w "${WS}/${name}")' -Force" >/dev/null 2>&1 || true
    elif command -v cmd.exe >/dev/null 2>&1; then
      MSYS_NO_PATHCONV=1 cmd.exe /c "mklink /J \"$(cygpath -w "${parent_ws}/${name}")\" \"$(cygpath -w "${WS}/${name}")\"" < /dev/null >/dev/null 2>&1 || true
    else
      ln -s "${WS}/${name}" "${parent_ws}/${name}" 2>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# Preflight: every named ref, checked before anything is cloned.
# ---------------------------------------------------------------------------
#
# This is here because of how this defect presented. A ref that does not exist
# is a CONFIGURATION mistake in this file, not a transient network fault, and it
# deserves to be reported as one -- naming the repo, the ref and the branches
# that do exist -- rather than surfacing as `git clone` exit 128 partway through
# a loop after some siblings have already landed on disk. `ls-remote` also
# travels the same scoped credential as the clones, so a preflight that passes
# is independent evidence that the credential is reaching github.com at all.
preflight() { # <owner/name> <rev>
  local repo="$1" rev="$2"
  # A separate `local`: a variable assigned earlier in the SAME `local` is not
  # yet visible to the ones after it (shellcheck SC2318), so folding this into
  # the line above would build the URL from an empty ${repo} and preflight the
  # wrong remote -- which, being a `ls-remote` of "https://github.com/.git",
  # would fail every pin and look exactly like the defect this script fixes.
  local url="${URL_BASE}${repo}.git"
  local out rc=0
  # `git -C "${NEUTRAL_DIR}"` -- RUN THIS FROM OUTSIDE THE CHECKOUT, and this
  # is not a stylistic preference.
  #
  # `actions/checkout` defaults to `persist-credentials: true`, which writes
  #
  #     http.https://github.com/.extraheader = AUTHORIZATION: basic <token>
  #
  # into the LOCAL `.git/config` of the consumer's checkout. A composite step
  # runs with its working directory set to that checkout, so a repo-aware git
  # command there reads that catch-all header AND the owner-scoped header this
  # script exports. `http.<url>.extraHeader` is MULTI-VALUED and both entries
  # match a `https://github.com/metacraft-labs/...` URL, so git sends TWO
  # `Authorization` headers and GitHub rejects the request:
  #
  #     remote: Duplicate header: "Authorization"
  #     fatal: unable to access '...': The requested URL returned error: 400
  #
  # Observed on a real consumer run before this line existed. `git clone` is
  # NOT affected -- it does not read a surrounding repository's local config,
  # which is why `clone-siblings` and `authenticated-clone.sh` have never hit
  # this -- but `ls-remote` is, so the preflight has to step outside.
  out="$(git -C "${NEUTRAL_DIR}" ls-remote --exit-code "${url}" "refs/heads/${rev}" 2>&1)" || rc=$?

  [ "${rc}" -eq 0 ] && return 0

  # A pinned SHA is legitimate and is not a branch ref.
  case "${rev}" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) return 0 ;;
  esac

  # EXIT CODE 2 IS THE ONLY ONE THAT MEANS "NO SUCH BRANCH". `--exit-code`
  # returns 2 when the query succeeded and matched nothing; anything else
  # (128, typically) means the QUERY failed -- no credential, no network, a
  # duplicated header -- and reporting that as a missing branch sends the
  # reader to fix a pin that was never wrong. The first version of this
  # function did exactly that, and announced "has no branch 'stable'" for a
  # repository whose `stable` branch is perfectly present.
  if [ "${rc}" -ne 2 ]; then
    echo "::error::reprobuild-provision: could not ask ${repo} whether it has '${rev}' (git exit ${rc}). This is a FAILED QUERY, not a missing branch -- the pin may be fine. git said:"
    printf '%s\n' "$(scrub_token "${out}")" >&2
    return 1
  fi

  echo "::error::reprobuild-provision: ${repo} has no branch '${rev}'. This is a wrong pin in reprobuild-provision/provision-reprobuild-siblings.sh, not a transient failure. Branches that do exist:"
  local line
  git -C "${NEUTRAL_DIR}" ls-remote --heads "${url}" 2>&1 |
    while IFS= read -r line; do
      printf '    %s\n' "${line##*refs/heads/}"
    done >&2
  return 1
}

PINS_OK=1
check_pins() { # <owner/name:rev>...
  local entry
  for entry in "$@"; do
    preflight "${entry%%:*}" "${entry##*:}" || PINS_OK=0
  done
  [ "${PINS_OK}" = 1 ] || {
    echo "::error::reprobuild-provision: refusing to clone anything while a pin above is wrong."
    exit 1
  }
}

if [ "${RUNNER_OS:-Linux}" != "Windows" ]; then
  # -----------------------------------------------------------------------
  # Linux/macOS: reprobuild's flake.nix references these as flake inputs.
  # The default repo-scoped token cannot read a sibling private repo through
  # the tarball URL, so they are cloned adjacent and the flake inputs are
  # overridden to the local paths.
  # -----------------------------------------------------------------------
  linux_pins=("${CLONE_OWNER}/runquota:${RUNQUOTA_REF}")
  if [ "${CLONE_NATIVE_RECORDER}" = 1 ]; then
    linux_pins=("${CLONE_OWNER}/codetracer-native-recorder:${CODETRACER_NATIVE_RECORDER_REF}" "${linux_pins[@]}")
  fi
  check_pins "${linux_pins[@]}"

  if [ "${CLONE_NATIVE_RECORDER}" = 1 ]; then
    clone "${CLONE_OWNER}/codetracer-native-recorder" "$CODETRACER_NATIVE_RECORDER_REF"
  fi
  clone "${CLONE_OWNER}/runquota" "$RUNQUOTA_REF"
else
  # -----------------------------------------------------------------------
  # Windows: reprobuild's env.ps1 reads sibling repos for source-only Nim deps.
  # The cold-start toolchain bootstrap (nim + gcc) is self-contained in
  # reprobuild/windows/bootstrap-toolchain.ps1 and no longer requires
  # the archived repo-workspaces framework.
  # -----------------------------------------------------------------------
  check_pins \
    "${CLONE_OWNER}/runquota:${RUNQUOTA_REF}" \
    "${CLONE_OWNER}/nim-stackable-hooks:${STACKABLE_HOOKS_REF}" \
    "${CLONE_OWNER}/io-mon:${IO_MON_REF}" \
    "${CLONE_OWNER}/codetracer:${CODETRACER_REF}" \
    "${CLONE_OWNER}/nim-shm-lease:${NIM_SHM_LEASE_REF}" \
    "${CLONE_OWNER}/nim-shm-queue:${NIM_SHM_QUEUE_REF}" \
    "${CLONE_OWNER}/nim-shm-gset:${NIM_SHM_GSET_REF}" \
    "${CLONE_OWNER}/reprobuild-test-adapters:${REPROBUILD_TEST_ADAPTERS_REF}" \
    "${CLONE_OWNER}/reprobuild-ct-test-runner:${REPROBUILD_CT_TEST_RUNNER_REF}" \
    "${CLONE_OWNER}/reprobuild-llm-agent-packages:${REPROBUILD_LLM_AGENT_PACKAGES_REF}" \
    "${CLONE_OWNER}/nim-cli-spec:${NIM_CLI_SPEC_REF}" \
    "${CLONE_OWNER}/nim-entrypoints:${NIM_ENTRYPOINTS_REF}" \
    "${CLONE_OWNER}/nim-confutils:${NIM_CONFUTILS_REF}" \
    "${CLONE_OWNER}/test-certificates-tools:${TEST_CERTIFICATES_TOOLS_REF}"

  clone "${CLONE_OWNER}/runquota" "$RUNQUOTA_REF" --submodules
  clone "${CLONE_OWNER}/nim-stackable-hooks" "$STACKABLE_HOOKS_REF" --submodules
  hooks_sha=$(git -C "${WS}/nim-stackable-hooks" rev-parse HEAD) || exit 1
  if [[ -n "$STACKABLE_HOOKS_PIN" && "$hooks_sha" != "$STACKABLE_HOOKS_PIN" ]]; then
    echo "::error::Windows hook bootstrap checkout does not match stackable-hooks-pin" >&2
    exit 1
  fi
  echo "reprobuild-provision: Windows hook source ${hooks_sha}"
  clone "${CLONE_OWNER}/io-mon" "$IO_MON_REF" --submodules
  clone "${CLONE_OWNER}/nim-shm-lease" "${NIM_SHM_LEASE_REF}"
  clone "${CLONE_OWNER}/nim-shm-queue" "${NIM_SHM_QUEUE_REF}"
  clone "${CLONE_OWNER}/nim-shm-gset" "${NIM_SHM_GSET_REF}"
  clone "${CLONE_OWNER}/reprobuild-test-adapters" "${REPROBUILD_TEST_ADAPTERS_REF}"
  clone "${CLONE_OWNER}/reprobuild-ct-test-runner" "${REPROBUILD_CT_TEST_RUNNER_REF}"
  clone "${CLONE_OWNER}/reprobuild-llm-agent-packages" "${REPROBUILD_LLM_AGENT_PACKAGES_REF}"
  # The CLI front end compiles against `../nim-cli-spec/src`,
  # `../nim-entrypoints/src` and `../nim-confutils` (CLI_SPEC_SRC,
  # ENTRYPOINTS_SRC and CONFUTILS_SRC in reprobuild's scripts/source_paths.sh);
  # without them build_apps stops at `missing <repo> source`. Linux/macOS get
  # them from the `nim-cli-spec-src`, `nim-entrypoints-src` and
  # `nim-confutils-src` flake inputs.
  clone "${CLONE_OWNER}/nim-cli-spec" "${NIM_CLI_SPEC_REF}"
  clone "${CLONE_OWNER}/nim-entrypoints" "${NIM_ENTRYPOINTS_REF}"
  clone "${CLONE_OWNER}/nim-confutils" "${NIM_CONFUTILS_REF}"
  # The engine links the `test_certificates` package (store, note framing,
  # two-note merge) from this sibling: without `../test-certificates-tools/src`
  # the engine compile stops at `certificate_store.nim: cannot open file:
  # test_certificates/roots` and the whole source build produces no `repro`.
  # Linux/macOS get it from the `test-certificates-tools-src` flake input.
  clone "${CLONE_OWNER}/test-certificates-tools" "$TEST_CERTIFICATES_TOOLS_REF"

  # `codetracer` gets a SELECTIVE submodule update, not `--submodules`. Its
  # tree carries far more submodules than the Windows env.ps1 build reads, and
  # one of them (`libs/tree-sitter-nim`) is private; pulling all of them
  # recursively would cost minutes per job for trees nothing here compiles.
  # The five below are the source-only Nim deps env.ps1 actually resolves.
  #
  # The credential travels to these child `git` processes through the
  # GIT_CONFIG_COUNT/KEY_n/VALUE_n pairs `scoped_git_auth_export` put in this
  # process's environment -- which is inherited at every submodule depth, and
  # is why the private submodule resolves without anything being written into
  # any `.git/config`.
  clone "${CLONE_OWNER}/codetracer" "${CODETRACER_REF}"
  submodule_log="$(mktemp "${NEUTRAL_DIR}/codetracer-submodules.XXXXXX")" || exit 1
  submodule_rc=0
  git -C "${WS}/codetracer" submodule update --init --depth 1 --recursive -- \
    libs/nim-serialization \
    libs/nim-faststreams \
    libs/nim-json-serialization \
    libs/nim-stew \
    libs/nimcrypto >"${submodule_log}" 2>&1 || submodule_rc=$?
  if [ "${submodule_rc}" -ne 0 ]; then
    report_submodule_failure "${submodule_rc}" "${submodule_log}"
    rm -f "${submodule_log}"
    exit 1
  fi
  # Keep git's progress in the job log, as it was when it streamed.
  scrub_token "$(cat "${submodule_log}")"
  echo
  rm -f "${submodule_log}"

  # -----------------------------------------------------------------------
  # status-im/nim-bearssl -- the third-party clone, authenticated too.
  # -----------------------------------------------------------------------
  #
  # Reprobuild's peer-cache apps import `status-im/nim-bearssl`. The Nix dev
  # shell supplies it through BEARSSL_SRC; Windows env.ps1 resolves it as a
  # sibling checkout.
  #
  # This block used to call itself "THE ONE CLONE THIS FIX DOES NOT
  # AUTHENTICATE", on the premise that the metacraft-labs App token cannot
  # cover another org. It can, for a PUBLIC repository -- see the measurement
  # at EXTRA_TOKEN_URL_PREFIXES above, which is what now authenticates this
  # clone and its `status-im/BearSSL` submodule through the same preemptive
  # header as every other clone here. Left anonymous, it was the one fetch on
  # this path still drawn against the fleet's shared per-IP budget.
  #
  # The URL stays credential-FREE, as everywhere else in this file: a
  # credential in a URL is not sent to a public repository at all (see the top
  # of this file), so it must travel in the header.
  bearssl_ref="9a4eed052abbded2d94feaf3f5bbd95a30ec4671"
  bearssl_dest="${WS}/nim-bearssl"
  echo "reprobuild-provision: status-im/nim-bearssl @ ${bearssl_ref} -> ${bearssl_dest} (authenticated through the declared '${STATUS_IM_SCOPE}' credential scope, submodule included)"
  rm -rf "${bearssl_dest}"
  if ! git clone --quiet --depth 1 --recurse-submodules \
    "${URL_BASE}status-im/nim-bearssl.git" "${bearssl_dest}"; then
    echo "::error::reprobuild-provision: cloning status-im/nim-bearssl failed. This clone is authenticated through the declared '${STATUS_IM_SCOPE}' credential scope (when a gh-token is supplied -- check the scope report above), so GitHub's 'temporarily limiting some unauthenticated downloads' here means the header did not reach git, not an expected consequence of fleet load."
    exit 1
  fi
  if ! git -C "${bearssl_dest}" fetch --quiet --depth 1 origin "${bearssl_ref}" ||
    ! git -C "${bearssl_dest}" checkout --quiet --detach FETCH_HEAD ||
    ! git -C "${bearssl_dest}" submodule update --init --recursive --depth 1; then
    echo "::error::reprobuild-provision: pinning status-im/nim-bearssl to ${bearssl_ref} failed."
    exit 1
  fi
fi

echo "reprobuild-provision: all siblings provisioned under ${WS}."
