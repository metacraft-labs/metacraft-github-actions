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
# The refs are pinned by NAME here rather than resolved at runtime. Reprobuild
# is not yet in the solved-graph lock contract (see this action's manifest), so
# a named mainline is the available pin; "whatever the default branch is today"
# would be no pin at all, which is the thing this org's sibling-resolution
# contract exists to prevent.
set -uo pipefail

# shellcheck source=../ci-roots/route.sh
. "${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../ci-roots/route.sh" || exit 1

GIT_AUTH_DIR="${GIT_AUTH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../git-auth" && pwd)}"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "${GIT_AUTH_DIR}/scoped-git-auth.sh"

# `//\\//` -- normalise the Windows separator, exactly as `clone-siblings.sh`
# does: this script runs under bash on the Windows runners too, where
# $GITHUB_WORKSPACE arrives backslashed.
WS="${MCL_WORKSPACE_ROOT//\\//}"
SIBLING_OWNER="${SIBLING_OWNER:-metacraft-labs}"
RUNQUOTA_REF="${RUNQUOTA_REF:-dev}"
IO_MON_REF="${IO_MON_REF:-dev}"
STACKABLE_HOOKS_PIN="${STACKABLE_HOOKS_PIN:-}"
if [[ -n "$STACKABLE_HOOKS_PIN" && ! "$STACKABLE_HOOKS_PIN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::stackable-hooks-pin must be a full lowercase source SHA" >&2
  exit 2
fi
STACKABLE_HOOKS_REF="${STACKABLE_HOOKS_PIN:-dev}"

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
# same budget. This does NOT widen any default: `TOKEN_OWNERS` is still the one
# sibling owner, and `setup-nix/configure-git-auth-test.sh` still asserts that
# `status-im` receives no credential under the default scope. The declaration
# is pinned on the wire by `test-bearssl-auth.py`.
#
# Built on GIT_AUTH_URL_BASE for the same reason `authenticated-clone.sh` is: it
# is github.com in production, and the contract suite points it at a local
# authenticating git server. `scoped_git_auth_build` refuses any base that is
# not github.com or loopback.
URL_BASE="${GIT_AUTH_URL_BASE:-https://github.com/}"
export TOKEN_OWNERS="${SIBLING_OWNER}"
STATUS_IM_SCOPE="${URL_BASE}status-im/"
export EXTRA_TOKEN_URL_PREFIXES="${STATUS_IM_SCOPE}"
export SCOPED_GIT_AUTH_REWRITES=1
export SCOPED_GIT_AUTH_MASK=1
scoped_git_auth_build || exit 1
scoped_git_auth_export
scoped_git_auth_report

if [ -z "${GH_TOKEN:-}" ]; then
  # Not fatal: `codetracer-native-recorder` is the only private entry, so a
  # tokenless run can still get some way in. It will however be cloning
  # anonymously, which is the exact condition this file exists to remove, so
  # it must not pass in silence.
  echo "::warning::reprobuild-provision: no 'gh-token' was supplied. Every clone below will be anonymous and subject to GitHub's per-IP unauthenticated download limit -- the failure mode this step was rewritten to eliminate. Private siblings will fail outright."
fi

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

  local parent_ws
  parent_ws="$(dirname "${WS}")"
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
  git -C "${NEUTRAL_DIR}" ls-remote --heads "${url}" 2>&1 |
    sed -e 's#^.*refs/heads/#    #' >&2
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
  check_pins \
    "${SIBLING_OWNER}/codetracer-native-recorder:stable" \
    "${SIBLING_OWNER}/runquota:${RUNQUOTA_REF}"

  clone "${SIBLING_OWNER}/codetracer-native-recorder" stable
  clone "${SIBLING_OWNER}/runquota" "$RUNQUOTA_REF"
else
  # -----------------------------------------------------------------------
  # Windows: reprobuild's env.ps1 reads sibling repos for source-only Nim deps.
  # The cold-start toolchain bootstrap (nim + gcc) is self-contained in
  # reprobuild/windows/bootstrap-toolchain.ps1 and no longer requires
  # the archived repo-workspaces framework.
  # -----------------------------------------------------------------------
  check_pins \
    "${SIBLING_OWNER}/runquota:${RUNQUOTA_REF}" \
    "${SIBLING_OWNER}/nim-stackable-hooks:${STACKABLE_HOOKS_REF}" \
    "${SIBLING_OWNER}/io-mon:${IO_MON_REF}" \
    "${SIBLING_OWNER}/codetracer:dev" \
    "${SIBLING_OWNER}/nim-shm-lease:dev" \
    "${SIBLING_OWNER}/nim-shm-queue:dev" \
    "${SIBLING_OWNER}/nim-shm-gset:dev" \
    "${SIBLING_OWNER}/reprobuild-test-adapters:dev" \
    "${SIBLING_OWNER}/reprobuild-ct-test-runner:dev" \
    "${SIBLING_OWNER}/reprobuild-llm-agent-packages:dev"

  clone "${SIBLING_OWNER}/runquota" "$RUNQUOTA_REF" --submodules
  clone "${SIBLING_OWNER}/nim-stackable-hooks" "$STACKABLE_HOOKS_REF" --submodules
  hooks_sha=$(git -C "${WS}/nim-stackable-hooks" rev-parse HEAD) || exit 1
  if [[ -n "$STACKABLE_HOOKS_PIN" && "$hooks_sha" != "$STACKABLE_HOOKS_PIN" ]]; then
    echo "::error::Windows hook bootstrap checkout does not match stackable-hooks-pin" >&2
    exit 1
  fi
  echo "reprobuild-provision: Windows hook source ${hooks_sha}"
  clone "${SIBLING_OWNER}/io-mon" "$IO_MON_REF" --submodules
  clone "${SIBLING_OWNER}/nim-shm-lease" dev
  clone "${SIBLING_OWNER}/nim-shm-queue" dev
  clone "${SIBLING_OWNER}/nim-shm-gset" dev
  clone "${SIBLING_OWNER}/reprobuild-test-adapters" dev
  clone "${SIBLING_OWNER}/reprobuild-ct-test-runner" dev
  clone "${SIBLING_OWNER}/reprobuild-llm-agent-packages" dev

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
  clone "${SIBLING_OWNER}/codetracer" dev
  if ! git -C "${WS}/codetracer" submodule update --init --depth 1 --recursive -- \
    libs/nim-serialization \
    libs/nim-faststreams \
    libs/nim-json-serialization \
    libs/nim-stew \
    libs/nimcrypto; then
    echo "::error::reprobuild-provision: updating codetracer's source-only Nim submodules failed. The scoped credential covers '${SIBLING_OWNER}' (plus the declared status-im prefix) only; a private submodule hosted under another owner cannot be authenticated by it."
    exit 1
  fi

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
