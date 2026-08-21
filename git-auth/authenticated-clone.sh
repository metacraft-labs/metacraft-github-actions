#!/usr/bin/env bash
#
# authenticated-clone.sh -- clone a GitHub repository (and its submodules, at
# any depth) with a credential that is never in a URL and never on disk.
#
# WHAT IT REPLACES
# ----------------
# `clone-repo` and `clone-siblings` each grew their own copy of
#
#     git clone https://x-access-token:$TOKEN@github.com/<owner>/<repo>.git
#     git -C <clone> config --add url."https://x-access-token:$TOKEN@github.com/".insteadOf \
#                                    "https://github.com/"
#     ...plus a per-submodule rewrite of submodule.<name>.url to the same shape
#
# so a live App token was written into the `.git/config` of the clone, of every
# submodule of the clone, and of every submodule of those -- files that outlive
# the step, sit next to the workspace, and on this org's self-hosted runners
# survive into the next job. The `insteadOf` was also a catch-all: it caught
# every github.com URL the clone would ever fetch, third parties included.
#
# This script clones from a CREDENTIAL-FREE URL and lets the credential travel
# as an owner-scoped `http.<url>.extraHeader` in process-scoped git
# configuration (`GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`), which child processes --
# including `git submodule update --recursive`, at every depth -- inherit and
# which nothing writes down. See ./scoped-git-auth.sh for how that scope is
# derived; the caller is expected to have called `scoped_git_auth_export`.
#
# THE PRIVATE-SUBMODULE PATH IS THE POINT, NOT A CASUALTY. `codetracer` has a
# private submodule (`libs/tree-sitter-nim`) inside a public repository, and
# `codetracer-native-backend` recurses into a private `codetracer-rr`. Both work
# because `url.<https>.insteadOf` covers the ssh spellings those `.gitmodules`
# use and the scoped header authenticates the resulting https fetch. Git applies
# `insteadOf` when it USES a URL, not when it records one, so this holds even for
# URLs `git submodule init` has already copied into `.git/config` -- both actions
# previously asserted the opposite in a comment and carried a per-submodule token
# rewrite to work around a behaviour git does not have.
#
# PORTABILITY. Pure bash builtins and `git`. No sed/awk/grep/find/mktemp: this
# runs inside `clone-siblings`, whose step executes in the consumer's dev-env
# shell, which may be a minimal Nix bash with no coreutils on PATH. Also bash
# 3.2-clean, because GitHub's macOS runner images ship bash 3.2.
#
# Usage:
#   authenticated-clone.sh --repo <owner/name> --dest <dir>
#                          [--rev <rev>] [--shallow] [--submodules]
#                          [--commit-https-gitmodules]
#                          [--url-base <https://github.com/>]
set -uo pipefail

REPO=""
DEST=""
REV=""
SHALLOW=0
SUBMODULES=0
SUBMODULES_OPTIONAL=0
COMMIT_GITMODULES=0
URL_BASE="${GIT_AUTH_URL_BASE:-https://github.com/}"

while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO="$2"
		shift 2
		;;
	--dest)
		DEST="$2"
		shift 2
		;;
	--rev)
		REV="$2"
		shift 2
		;;
	--url-base)
		URL_BASE="$2"
		shift 2
		;;
	--shallow)
		SHALLOW=1
		shift
		;;
	--submodules)
		SUBMODULES=1
		shift
		;;
	--submodules-optional)
		SUBMODULES=1
		SUBMODULES_OPTIONAL=1
		shift
		;;
	--commit-https-gitmodules)
		COMMIT_GITMODULES=1
		shift
		;;
	*)
		echo "authenticated-clone: unknown argument '$1'" >&2
		exit 2
		;;
	esac
done

[ -n "$REPO" ] || {
	echo "authenticated-clone: --repo is required" >&2
	exit 2
}
[ -n "$DEST" ] || {
	echo "authenticated-clone: --dest is required" >&2
	exit 2
}

OWNER="${REPO%%/*}"
URL="${URL_BASE}${REPO}.git"

# `scrub <text>` -- the only sanctioned way anything derived from a git
# invocation reaches a log. A credential-free URL is the invariant this script
# maintains, and the check at the end enforces it, but a diagnostic path is
# exactly where an invariant gets discovered to be false, and discovering it by
# printing the token into a public Actions log is not an acceptable way to find
# out.
scrub() {
	local text="$1"
	if [ -n "${GH_TOKEN:-}" ]; then
		text="${text//${GH_TOKEN}/\*\*\*}"
	fi
	printf '%s' "$text"
}

# `run_git <describe> <args...>` -- run git quietly, and on failure print what
# it said, scrubbed, with a diagnostic that names the owner.
#
# The previous implementations ran `git clone ... >/dev/null 2>&1`, so a private
# sibling that failed to authenticate produced NO output at all: the step then
# failed several commands later with something unrelated. With an owner-scoped
# credential the auth-denied case is reachable by a plain configuration
# mismatch, so it has to be the loudest thing in the log, not the quietest.
run_git() {
	local what="$1"
	shift
	local out rc=0
	out="$(git "$@" 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "::error::${what} failed for ${REPO} (git exit ${rc})." >&2
		echo "--- git output ---" >&2
		scrub "$out" >&2
		printf '\n------------------\n' >&2
		if [ -z "${GH_TOKEN:-}" ]; then
			echo "No token was supplied to this action, so only public repositories can be cloned. If ${REPO} is private, pass 'gh-token'." >&2
		else
			echo "A token WAS supplied. It is installed as an owner-scoped 'http.<url>.extraHeader', so it authenticates ${URL_BASE}<owner>/ for the owners in 'token-owner' and nothing else. If ${OWNER} is not one of them, GitHub answers 404 for a private repository -- indistinguishable from a wrong name. Check that '${OWNER}' is covered." >&2
		fi
		return "$rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Windows MAX_PATH: git's own long-path opt-in, before the first git runs.
# ---------------------------------------------------------------------------
#
# Git for Windows refuses any path over 260 characters with
#
#     error: unable to create file <path>: Filename too long
#
# unless `core.longpaths` is true, at which point it addresses the file through
# the `\\?\` form and the limit becomes ~32767. This org's Windows jobs start at
# `C:\actions-runner\_work\<repo>\`, `clone-siblings` puts each sibling next to
# that, and `codetracer` -- a sibling of nearly everything -- nests submodules
# that themselves recurse. The `submodule update` at the bottom of this file is
# where that ran out, reported through this script's own `run_git` diagnostic:
#
#     ::error::submodule update failed for metacraft-labs/codetracer (git exit 1).
#     --- git output ---
#     error: unable to create file ...: Filename too long
#
# THE REGISTRY POLICY IS NOT A SUBSTITUTE, and this is the part that gets
# assumed. `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled`
# lifts MAX_PATH for binaries that declare themselves long-path aware in their
# manifest -- which is what the compilers, cargo, tup and the .NET runner that
# later READ the tree need -- but git gates its `\\?\` expansion on this config
# key and errors out whatever the OS policy says. The two halves cover different
# processes; the OS half is provisioned in the `infra` repo
# (machines/server/_win-ci-*/system_windows_runner.nim, gated by
# checks/t_windows_long_paths.sh), and this is the git half.
#
# DO NOT DELETE THIS AS "NOW REDUNDANT" once you see the same setting in a
# runner profile. Those profiles converge onto the PERSISTENT Windows boxes
# (win-ci-vm-001, win-ci-bare-001) only. Every job that hit this defect runs on
# `eph-win-x64`, whose runners are copy-on-write clones of a PRE-BAKED golden
# image that no converge loop reaches, and the respin that would put either half
# into that image is deliberately deferred until a non-git tool is actually
# observed failing on MAX_PATH (recorded in the infra repo's
# docs/runbooks/Ephemeral-Runner-Fleet.runbook.md, §12). So on the class where
# the failure was reported, THIS is the only half in force -- and it stays the
# only one that needs no image at all, which is what makes it the half that
# still works on a runner booted from a stale image.
#
# The one surface it does NOT reach is the consumer's own `actions/checkout`
# step: that git is not a child of this process. `codetracer` covers that with
# `ci/ensure-git-for-checkout.ps1`, which runs before checkout on every
# eph-win-x64 job.
#
# WHY PROCESS-SCOPED CONFIGURATION RATHER THAN `git -C "$DEST" config`. A
# submodule is its own repository with its own config file, so a setting on the
# superproject is not read by the git processes that check the submodules out --
# and the submodules are where the deep paths are. `GIT_CONFIG_COUNT` /
# `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` is inherited by every child git at
# every depth: git's `prepare_submodule_repo_env` scrubs the local-repo
# variables but deliberately KEEPS these two, which is the same mechanism that
# makes the well-known `git -c protocol.file.allow=always submodule update`
# workaround reach submodules. ./longpaths-test.sh observes that rather than
# assuming it, with `GIT_TRACE2_CONFIG_PARAMS`.
#
# It is set unconditionally rather than under a Windows test. On Linux and macOS
# `core.longpaths` is an unrecognised `core.*` key that git ignores in silence,
# so there is one code path and it is the one the suite exercises -- as opposed
# to a Windows-only branch that no suite in this repo can reach.
#
# APPENDING, for the same reason `scoped_git_auth_export` appends: a caller may
# already have numbered configuration in the environment (`setup-nix` puts the
# job's credential there), and renumbering from zero would silently drop it.
# Appending is also what makes this authoritative rather than merely present --
# git applies the pairs in order and the last value of a single-valued key wins,
# so an inherited `core.longpaths=false` cannot defeat it.
git_longpaths_export() {
	local n="${GIT_CONFIG_COUNT:-0}" j kn vn last=""
	for ((j = 0; j < n; j++)); do
		kn="GIT_CONFIG_KEY_${j}"
		vn="GIT_CONFIG_VALUE_${j}"
		if [ "${!kn-}" = "core.longpaths" ]; then
			last="${!vn-}"
		fi
	done
	# Already in force: adding a second identical pair would be a no-op that
	# grows the environment on every nested invocation.
	[ "$last" = "true" ] && return 0
	printf -v "GIT_CONFIG_KEY_${n}" '%s' "core.longpaths"
	printf -v "GIT_CONFIG_VALUE_${n}" '%s' "true"
	export "GIT_CONFIG_KEY_${n}" "GIT_CONFIG_VALUE_${n}"
	export GIT_CONFIG_COUNT="$((n + 1))"
}

git_longpaths_export

rm -rf "$DEST"

if [ "$SHALLOW" = 1 ]; then
	# Sibling clones only ever check out one pinned revision, so the history is
	# dead weight; `--no-checkout` + a depth-1 fetch of the exact rev is what
	# `clone-siblings` has always done.
	run_git "clone" clone --no-checkout --quiet "$URL" "$DEST" || exit 1
	if [ -n "$REV" ]; then
		run_git "fetch of revision ${REV}" -C "$DEST" fetch --quiet --depth 1 origin "$REV" || exit 1
		run_git "checkout of revision ${REV}" -C "$DEST" checkout --quiet --detach FETCH_HEAD || exit 1
	fi
else
	run_git "clone" clone --quiet "$URL" "$DEST" || exit 1
	if [ -n "$REV" ]; then
		run_git "checkout of revision ${REV}" -C "$DEST" checkout --quiet "$REV" || exit 1
	fi
fi

# ---------------------------------------------------------------------------
# .gitmodules normalisation (opt-in), for Nix's flake fetcher.
# ---------------------------------------------------------------------------
#
# Nix resolves a submodule's URL with libgit2's `git_submodule_resolve_url`,
# which handles relative URLs and nothing else -- in particular it does not
# apply `url.*.insteadOf`. The resolved URL then goes to Nix's git fetcher,
# which since 2.20 shells out to the `git` binary and so DOES apply `insteadOf`
# -- but only for a URL Nix managed to parse and hand over, and scp-style
# `git@github.com:owner/repo` is not a URL. Normalising the file to https in the
# tree keeps `?submodules=1` flake evaluation working regardless.
#
# It is committed because a flake reference pinned to a revision reads
# `.gitmodules` from that commit, not from the worktree.
#
# The committed content is credential-FREE by construction -- the rewrite target
# is a bare, userinfo-less base URL -- and the check below refuses to commit if
# that ever stops being true, whether because this rewrite changed or because
# the upstream `.gitmodules` already carried one. A credential in a committed
# `.gitmodules` is a credential in a git object, which is the one place a later
# `git push` or a packed artifact carries it off the machine.
if [ "$COMMIT_GITMODULES" = 1 ] && [ -f "$DEST/.gitmodules" ]; then
	gm="$(<"$DEST/.gitmodules")"
	# The rewrite target is $URL_BASE, not a literal, for the same reason the
	# clone URL is: it is the one https base this run is talking to. In
	# production it IS `https://github.com/`; in the contract suite it is the
	# suite's own server, which is what lets the suite check that the rewritten
	# file is actually fetchable rather than merely differently spelled.
	gm="${gm//git@github.com:/${URL_BASE}}"
	gm="${gm//ssh:\/\/git@github.com\//${URL_BASE}}"
	case "$gm" in
	*x-access-token* | *://*:*@*)
		echo "::error::refusing to commit .gitmodules for ${REPO}: it carries a credential. This is the invariant this action exists to keep; nothing is committed." >&2
		exit 1
		;;
	esac
	printf '%s\n' "$gm" >"$DEST/.gitmodules"
	run_git "staging .gitmodules" -C "$DEST" add .gitmodules || exit 1
	# `|| true`: an unchanged .gitmodules makes `commit` exit 1 with "nothing to
	# commit", which is the common case and not a failure.
	git -C "$DEST" -c user.name="CI" -c user.email="ci@local" commit --quiet \
		--no-gpg-sign -m "CI: rewrite submodule URLs to HTTPS" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Submodules, at every depth, on the inherited scoped credential.
# ---------------------------------------------------------------------------
if [ "$SUBMODULES" = 1 ]; then
	# `--submodules-optional` preserves `clone-siblings`' long-standing
	# tolerance here (its `submodule update` ended in `|| true`). What it does
	# NOT preserve is the silence: the same line also sent stderr to /dev/null,
	# so a sibling whose private submodule failed to authenticate produced an
	# empty directory and not one word about it, and the job failed later
	# somewhere unrelated. Changing tolerance into a hard failure org-wide is a
	# separate decision from removing a credential from disk, so this change
	# only makes the failure visible.
	if ! run_git "submodule update" -C "$DEST" submodule update --init --recursive --quiet; then
		if [ "$SUBMODULES_OPTIONAL" = 1 ]; then
			echo "::warning::submodules of ${REPO} could not be updated; continuing with them missing. If a build later fails on an empty submodule directory, this is why." >&2
		else
			exit 1
		fi
	fi
fi

# ---------------------------------------------------------------------------
# The invariant, enforced at runtime and not only in the suite.
# ---------------------------------------------------------------------------
#
# Everything above is arranged so that no credential is written down. This
# checks it, on every real run, because the suite tests the code as written and
# this catches the case where a future edit -- or a git version with different
# ideas about what to record in `.git/config` -- makes it false in production
# first. It reports FILE NAMES only, never a line and never a value.
CRED_FILES=""

check_file() {
	[ -f "$1" ] || return 0
	local content
	content="$(<"$1")"
	case "$content" in
	*x-access-token*) CRED_FILES="${CRED_FILES} $1" ;;
	esac
	if [ -n "${GH_TOKEN:-}" ]; then
		case "$content" in
		*"${GH_TOKEN}"*) CRED_FILES="${CRED_FILES} $1" ;;
		esac
	fi
}

# Pure-bash recursive walk: `find` is not assumed present, and bash 3.2 has no
# globstar.
walk_configs() {
	local d="$1" e
	[ -d "$d" ] || return 0
	for e in "$d"/*; do
		[ -e "$e" ] || continue
		if [ -d "$e" ]; then
			walk_configs "$e"
		elif [ "${e##*/}" = "config" ]; then
			check_file "$e"
		fi
	done
}

check_file "$DEST/.gitmodules"
check_file "$DEST/.git/config"
walk_configs "$DEST/.git/modules"

if [ -n "$CRED_FILES" ]; then
	echo "::error::authenticated-clone wrote a credential to disk in ${DEST}. This must never happen; the clone has been removed. Offending file(s):${CRED_FILES}" >&2
	rm -rf "$DEST"
	exit 1
fi

exit 0
