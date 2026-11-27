#!/usr/bin/env bash
# Choose the Reprobuild revision setup-reprobuild installs.
#
# The default is `pins/reprobuild.json` in the checkout this script came from:
# the organisation's one Reprobuild pin (pins/README.md, pins/pin.schema.json).
# It must carry `version` and `kind`, which the schema leaves optional. A caller's
# `repro-build-pin` or `repro-version` overrides it. There is no branch, `dev`
# or `latest` default: with no override the pinned commit is installed, and an
# unreadable or malformed pin fails the step.
#
# setup-reprobuild and setup-dev-env both run this script from their own
# checkout, so each reads the pin of the revision the caller named in `uses:`.
#
# The pin is read with Bash builtins on Linux and macOS, because a
# self-hosted runner's PATH can be a Nix profile without coreutils. On Windows
# it is parsed by PowerShell's ConvertFrom-Json (read-pin.ps1).
#
# Environment:
#   REPRO_PIN_FILE   the pin; default <this directory>/../pins/reprobuild.json
#   REPRO_BUILD_PIN  explicit source revision override, or empty
#   REPRO_VERSION    explicit release override, or empty
#   FROM_SOURCE      `true` never installs a release
#   RUNNER_OS        `Windows` selects the PowerShell reader
#   GITHUB_OUTPUT    receives the results below
#
# Results (key=value lines in GITHUB_OUTPUT):
#   origin            `pin` or `override`
#   pin-commit        the pin's commit, pin-version its version, pin-kind its kind
#   release-version   the release to install prebuilt; empty installs none
#   build-ref         the source revision to build when no release is
#                     installed; empty only for an override that names a
#                     release, whose fallback builds the release it resolved
#   from-source       `true` when the selection is a source build, which
#                     every commit selection is
#   source-requested  `true` when the caller asked for a source build
#                     (FROM_SOURCE is the literal `true`). It keeps a prebuilt
#                     of the selected commit, Windows' pin prerelease, out;
#                     setup-dev-env forwards it as the leaf's from-source
#   expected-version  what `repro --version` must report; empty for an override
#   expected-commit   the commit a source build must have checked out; empty
#                     unless the build ref is a full commit SHA

set -uo pipefail

fail() {
  printf '::error::setup-reprobuild: %s\n' "$*"
  exit 1
}

# Git Bash on Windows may name this script with backslashes.
script_path="${BASH_SOURCE[0]//\\//}"
script_dir="${script_path%/*}"
[ "${script_dir}" = "${script_path}" ] && script_dir=.
pin_file="${REPRO_PIN_FILE:-${script_dir}/../pins/reprobuild.json}"
[ -f "${pin_file}" ] || fail "the Reprobuild pin ${pin_file} does not exist"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

schema="" owner="" repo="" commit="" version="" kind=""

if [ "${RUNNER_OS:-}" = Windows ]; then
  # Windows: the pin is parsed natively. Paths go to pwsh in Windows form.
  reader="${script_dir}/read-pin.ps1"
  pin_arg="${pin_file}"
  if command -v cygpath >/dev/null 2>&1; then
    reader="$(cygpath -w "${reader}")"
    pin_arg="$(cygpath -w "${pin_file}")"
  fi
  fields="$(pwsh -NoProfile -NonInteractive -File "${reader}" -Path "${pin_arg}")" \
    || fail "could not read the Reprobuild pin ${pin_file}"
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    case "${key}" in
      schema) schema="${value}" ;;
      owner) owner="${value}" ;;
      repo) repo="${value}" ;;
      rev) commit="${value}" ;;
      version) version="${value}" ;;
      kind) kind="${value}" ;;
    esac
  done <<< "${fields}"
else
  json="$(< "${pin_file}")"
  # tools/check-pins.py, run by the `pins` workflow on every change,
  # validates each pin against pins/pin.schema.json with a real JSON parser,
  # so this reader only has to find the value of each top-level field it
  # uses. None of their names is an `attrs` role of this pin.
  field() {
    local pattern="\"$1\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]*)\"|[0-9]+)"
    if [[ ${json} =~ ${pattern} ]]; then
      local value="${BASH_REMATCH[1]}"
      value="${value#\"}"
      printf '%s' "${value%\"}"
    fi
  }
  schema="$(field schema)"
  owner="$(field owner)"
  repo="$(field repo)"
  commit="$(field rev)"
  version="$(field version)"
  kind="$(field kind)"
fi

[ "${schema}" = 1 ] || fail "${pin_file}: schema is '${schema}', not 1"
[ "${owner}/${repo}" = metacraft-labs/reprobuild ] \
  || fail "${pin_file}: the repository is '${owner}/${repo}', not metacraft-labs/reprobuild"
[[ ${commit} =~ ^[0-9a-f]{40}$ ]] \
  || fail "${pin_file}: rev '${commit}' is not a full lowercase 40-hex commit SHA"
[[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] \
  || fail "${pin_file}: version '${version}' is not a version number"
case "${kind}" in
  dev-commit | agents-commit | release) ;;
  *) fail "${pin_file}: kind '${kind}' is not dev-commit, agents-commit or release" ;;
esac
# A release pin names the commit of the release tagged v<version>.
tag="v${version}"

build_pin="${REPRO_BUILD_PIN:-}"
requested_release="${REPRO_VERSION:-}"
from_source="${FROM_SOURCE:-false}"
source_requested=false
[ "${from_source}" = true ] && source_requested=true

if [ -n "${build_pin}" ] || [ -n "${requested_release}" ]; then
  origin=override
  expected_version=""
  build_ref="${build_pin}"
  release_version=""
  if [ "${from_source}" = true ]; then
    if [ -z "${build_ref}" ]; then
      # A source build of a named release builds that release's tag.
      [ "${requested_release}" != latest ] \
        || fail "from-source with repro-version latest names no revision; pass repro-build-pin"
      build_ref="v${requested_release#v}"
    fi
  else
    release_version="${requested_release}"
  fi
else
  origin=pin
  expected_version="${version}"
  build_ref="${commit}"
  release_version=""
  if [ "${kind}" = release ] && [ "${from_source}" != true ]; then
    release_version="${tag}"
  fi
fi

if [ -n "${release_version}" ]; then from_source=false; else from_source=true; fi
expected_commit=""
[[ ${build_ref} =~ ^[0-9a-f]{40}$ ]] && expected_commit="${build_ref}"

{
  printf 'origin=%s\n' "${origin}"
  printf 'pin-commit=%s\n' "${commit}"
  printf 'pin-version=%s\n' "${version}"
  printf 'pin-kind=%s\n' "${kind}"
  printf 'release-version=%s\n' "${release_version}"
  printf 'build-ref=%s\n' "${build_ref}"
  printf 'from-source=%s\n' "${from_source}"
  printf 'source-requested=%s\n' "${source_requested}"
  printf 'expected-version=%s\n' "${expected_version}"
  printf 'expected-commit=%s\n' "${expected_commit}"
} >> "${GITHUB_OUTPUT}"

if [ "${origin}" = pin ]; then
  echo "setup-reprobuild: installing the pinned Reprobuild ${version} (${kind} ${commit}) from ${pin_file}"
else
  echo "setup-reprobuild: the caller overrides the pinned Reprobuild ${version} (${commit}): repro-version='${requested_release}' repro-build-pin='${build_pin}'"
fi
