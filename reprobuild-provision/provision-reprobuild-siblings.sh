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
#     repo-workspaces      main: absent   mainline: dev
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

GIT_AUTH_DIR="${GIT_AUTH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../git-auth" && pwd)}"
# shellcheck source=../git-auth/scoped-git-auth.sh
. "${GIT_AUTH_DIR}/scoped-git-auth.sh"

# `//\\//` -- normalise the Windows separator, exactly as `clone-siblings.sh`
# does: this script runs under bash on the Windows runners too, where
# $GITHUB_WORKSPACE arrives backslashed.
WS="${GITHUB_WORKSPACE//\\//}"
SIBLING_OWNER="${SIBLING_OWNER:-metacraft-labs}"

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
# The scope is ONE owner because that is what the CI App token covers. The
# `status-im/nim-bearssl` clone on the Windows path is therefore deliberately
# NOT authenticated -- see the note at that clone.
export TOKEN_OWNERS="${SIBLING_OWNER}"
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
	local url="https://github.com/${repo}.git"
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
		"${SIBLING_OWNER}/runquota:dev"

	clone "${SIBLING_OWNER}/codetracer-native-recorder" stable
	clone "${SIBLING_OWNER}/runquota" dev
else
	# -----------------------------------------------------------------------
	# Windows: reprobuild's env.ps1 dot-sources ../repo-workspaces/env.ps1 for
	# the toolchain bootstrap and reads sibling repos for source-only Nim deps.
	# -----------------------------------------------------------------------
	check_pins \
		"${SIBLING_OWNER}/repo-workspaces:dev" \
		"${SIBLING_OWNER}/runquota:dev" \
		"${SIBLING_OWNER}/nim-stackable-hooks:stable" \
		"${SIBLING_OWNER}/io-mon:stable" \
		"${SIBLING_OWNER}/codetracer:stable"

	clone "${SIBLING_OWNER}/repo-workspaces" dev --submodules
	clone "${SIBLING_OWNER}/runquota" dev --submodules
	clone "${SIBLING_OWNER}/nim-stackable-hooks" stable --submodules
	clone "${SIBLING_OWNER}/io-mon" stable --submodules

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
	clone "${SIBLING_OWNER}/codetracer" stable
	if ! git -C "${WS}/codetracer" submodule update --init --depth 1 --recursive -- \
		libs/nim-serialization \
		libs/nim-faststreams \
		libs/nim-json-serialization \
		libs/nim-stew \
		libs/nimcrypto; then
		echo "::error::reprobuild-provision: updating codetracer's source-only Nim submodules failed. The scoped credential covers '${SIBLING_OWNER}' only; a submodule hosted under another owner cannot be authenticated by it."
		exit 1
	fi

	# -----------------------------------------------------------------------
	# status-im/nim-bearssl -- THE ONE CLONE THIS FIX DOES NOT AUTHENTICATE.
	# -----------------------------------------------------------------------
	#
	# Reprobuild's peer-cache apps import `status-im/nim-bearssl`. The Nix dev
	# shell supplies it through BEARSSL_SRC; Windows env.ps1 resolves it as a
	# sibling checkout.
	#
	# It is fetched anonymously and there is no honest way to change that from
	# here. The CI credential is a GitHub App INSTALLATION token for the
	# `metacraft-labs` org; `status-im` is a different org with no installation
	# of that app, and the owner-scoped header deliberately does not cover it
	# (`authenticated-clone-test.sh` asserts that a third-party owner receives
	# no credential, and that assertion is correct and should stay).
	#
	# So this clone remains subject to the same per-IP anonymous limit as
	# before. It is a PUBLIC third-party repository on the WINDOWS path only,
	# and closing it needs a credential this org does not currently have -- see
	# the action manifest for what that would take. It is called out loudly
	# rather than quietly retried, because an unauthenticated fallback that
	# usually works is how a hard failure becomes an intermittent one.
	bearssl_ref="9a4eed052abbded2d94feaf3f5bbd95a30ec4671"
	bearssl_dest="${WS}/nim-bearssl"
	echo "reprobuild-provision: status-im/nim-bearssl @ ${bearssl_ref} -> ${bearssl_dest} (ANONYMOUS: the metacraft-labs App token cannot authenticate another org; this clone alone remains exposed to GitHub's per-IP unauthenticated limit)"
	rm -rf "${bearssl_dest}"
	if ! git clone --quiet --depth 1 --recurse-submodules \
		"https://github.com/status-im/nim-bearssl.git" "${bearssl_dest}"; then
		echo "::error::reprobuild-provision: cloning status-im/nim-bearssl failed. This is the one clone on this path that is unauthenticated by necessity (see the comment above it), so a GitHub 'temporarily limiting some unauthenticated downloads' error here is expected under fleet load and is NOT the same defect as the metacraft-labs clones above."
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
