#!/usr/bin/env bash
# Name the Reprobuild commit, version and origin of the `repro` this job
# installed, for setup-dev-env's `repro-commit`, `repro-version`,
# `repro-origin` and `repro-install-source` outputs.
#
# Runs after "Check the installed repro is the selected one (reprobuild)",
# which has already compared the CLI's version with the selection and a source
# build's checkout with the selected commit. This script only reports, and it
# fails closed: when it cannot name the commit, the step fails rather than
# hand a consumer an empty `repro-commit` to compare against.
#
# Why a commit for every route: consumer workflows used to assert
# `git -C .reprobuild-src rev-parse HEAD` against a literal revision. They now
# compare against this output, so the revision lives only in
# pins/reprobuild.json (pins/README.md, metacraft-pm
# milestones/Single-Tool-Pins.milestones.org, STP2).
#
# How each install route knows its commit (setup-reprobuild's
# `install-source`):
#
#   source       the built checkout's HEAD, which the check step read
#                (CHECKED_COMMIT). That covers Linux/macOS Nix builds, the
#                Windows env.ps1 (DIY) build, and an override that names a
#                branch or a tag, which resolves to a commit only here.
#   package      the selection's build ref. setup-reprobuild admits a caller's
#   cache        package, substitutes a cached one, or installs a `pin-<commit>`
#   pin-release  prerelease only for a full commit SHA, and only when the
#                artifact is that commit's own (bind-repro-package.sh,
#                substitute-repro-package.sh, install-pin-release.sh).
#   release      for the pin, the pin's `rev`: a `release` pin names the commit
#                of its tag, which `tools/check-pins.py --remote` verifies on
#                every change to the pin. For a `repro-version` override the
#                release tag is resolved with `git ls-remote` against the
#                Reprobuild repository (peeling an annotated tag), because
#                the archive and `repro --version` carry no commit.
#
# Environment:
#   INSTALL_SOURCE    setup-reprobuild's `install-source`
#   ORIGIN            `pin` or `override`, from resolve-reprobuild-pin.sh
#   PIN_COMMIT        the pin's rev, from resolve-reprobuild-pin.sh
#   PIN_KIND          the pin's kind
#   BUILD_REF         the selection's build ref
#   RELEASE_VERSION   the selection's release to install, or empty
#   CHECKED_VERSION   the version the check step read from `repro --version`
#   CHECKED_COMMIT    the source checkout's commit the check step read, or empty
#   REPRO_SOURCE_URL  the repository a release tag is resolved in; default
#                     https://github.com/metacraft-labs/reprobuild.git
#   GITHUB_OUTPUT     receives `commit`, `version`, `origin`, `install-source`
#
# Bash builtins and `git` only: the job's PATH can be a Nix profile without
# coreutils.

set -uo pipefail

fail() {
  printf '::error::setup-dev-env: %s\n' "$*"
  exit 1
}

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

install_source="${INSTALL_SOURCE:-}"
origin="${ORIGIN:-}"
version="${CHECKED_VERSION:-}"
build_ref="${BUILD_REF:-}"
sha_pattern='^[0-9a-f]{40}$'

case "${origin}" in
  pin | override) ;;
  *) fail "the Reprobuild selection reported origin '${origin}', not pin or override" ;;
esac
[ -n "${version}" ] || fail "the installed repro reported no version"

commit=""
case "${install_source}" in
  source)
    commit="${CHECKED_COMMIT:-}"
    [ -n "${commit}" ] \
      || fail "repro was built from source, but the check step read no commit from its checkout"
    ;;
  package | cache | pin-release)
    [[ ${build_ref} =~ ${sha_pattern} ]] \
      || fail "install route '${install_source}' admits only a full commit SHA, but the selection's build ref is '${build_ref}'"
    commit="${build_ref}"
    ;;
  release)
    if [ "${origin}" = pin ]; then
      [ "${PIN_KIND:-}" = release ] \
        || fail "a release was installed for a '${PIN_KIND:-}' pin, which names no release"
      commit="${PIN_COMMIT:-}"
    else
      # A `latest` override names no tag; the installed CLI's version does.
      tag="${RELEASE_VERSION:-}"
      if [ -z "${tag}" ] || [ "${tag}" = latest ]; then
        tag="v${version}"
      else
        tag="v${tag#v}"
      fi
      url="${REPRO_SOURCE_URL:-https://github.com/metacraft-labs/reprobuild.git}"
      refs="$(git ls-remote "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}")" \
        || fail "cannot resolve the installed release ${tag} to a commit in ${url}"
      # An annotated tag lists its object and the peeled commit (`^{}`); a
      # lightweight tag lists only the commit. Prefer the peeled line.
      while IFS=$'\t' read -r sha ref; do
        case "${ref}" in
          "refs/tags/${tag}^{}") commit="${sha}" ;;
          "refs/tags/${tag}") [ -n "${commit}" ] || commit="${sha}" ;;
        esac
      done <<< "${refs}"
      [ -n "${commit}" ] || fail "the release tag ${tag} does not exist in ${url}"
    fi
    ;;
  *) fail "setup-reprobuild reported install source '${install_source}', which this step does not know" ;;
esac

[[ ${commit} =~ ${sha_pattern} ]] \
  || fail "the installed repro's commit '${commit}' is not a full lowercase commit SHA"

{
  printf 'commit=%s\n' "${commit}"
  printf 'version=%s\n' "${version}"
  printf 'origin=%s\n' "${origin}"
  printf 'install-source=%s\n' "${install_source}"
} >> "${GITHUB_OUTPUT}"
echo "setup-dev-env: repro ${version} from ${install_source} at ${commit} (${origin})"
