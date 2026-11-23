#!/usr/bin/env bash
# Check that the `repro` this job will run is the one that was selected.
#
# Runs after setup-reprobuild has put a `repro` on PATH. It reports the
# version that CLI prints and, for a source build, the commit its checkout is
# at, and it fails when they are not what resolve-reprobuild-pin.sh selected:
#
#   EXPECTED_VERSION  `repro --version` must print `repro <this>`; empty skips
#                     the comparison (an override names no version)
#   EXPECTED_COMMIT   a source build's checkout must be at this commit; empty
#                     skips the comparison
#   SOURCE_DIR        that checkout; empty when no source build ran
#   REPRO_BIN_DIR     the directory setup-reprobuild selected, or empty to
#                     resolve `repro` from PATH (a source build adds its own
#                     bin/ to PATH)
#
# Results (key=value lines in GITHUB_OUTPUT): `version` (the bare version the
# CLI reports) and `commit` (the source build's commit, else empty).
#
# Bash builtins only, apart from `git` for a source checkout: the job's PATH
# can be a Nix profile without coreutils.

set -uo pipefail

fail() {
  printf '::error::setup-reprobuild: %s\n' "$*"
  exit 1
}

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

repro=repro
if [ -n "${REPRO_BIN_DIR:-}" ]; then
  repro="${REPRO_BIN_DIR}/repro"
  [ "${RUNNER_OS:-}" = Windows ] && repro="${repro}.exe"
fi
reported="$("${repro}" --version)" || fail "'${repro} --version' failed"
# The first line; native Windows ends it with CR.
reported="${reported%%$'\n'*}"
reported="${reported%$'\r'}"
case "${reported}" in
  "repro "*) version="${reported#repro }" ;;
  *) fail "'${repro} --version' printed '${reported}', not 'repro <version>'" ;;
esac

if [ -n "${EXPECTED_VERSION:-}" ] && [ "${version}" != "${EXPECTED_VERSION}" ]; then
  fail "the pin names Reprobuild ${EXPECTED_VERSION}, but the installed CLI reports '${reported}'"
fi

commit=""
if [ -n "${SOURCE_DIR:-}" ]; then
  commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)" \
    || fail "cannot read the commit of the source build at ${SOURCE_DIR}"
  if [ -n "${EXPECTED_COMMIT:-}" ] && [ "${commit}" != "${EXPECTED_COMMIT}" ]; then
    fail "the source build at ${SOURCE_DIR} is at ${commit}, not the selected ${EXPECTED_COMMIT}"
  fi
fi

printf 'version=%s\ncommit=%s\n' "${version}" "${commit}" >> "${GITHUB_OUTPUT}"
echo "setup-reprobuild: ${reported}${commit:+ built from ${commit}}"
