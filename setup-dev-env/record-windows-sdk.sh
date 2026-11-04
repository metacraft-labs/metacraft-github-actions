#!/usr/bin/env bash
# Observe the SDK used by setup, without installing tools or changing its env.
# Image fingerprints identify bytes; they do not prove daemon selection, leases,
# native ARM execution, or cross-job cache reuse.
set -euo pipefail

fingerprint() {
  local role=$1 path=$2 digest
  if [[ ! -f "$path" ]]; then
    printf 'setup-dev-env: sdk-file role=%s state=missing path=%q\n' "$role" "$path"
    return 0
  fi
  digest=$(sha256sum < "$path")
  digest=${digest%% *}
  printf 'setup-dev-env: sdk-file role=%s sha256=%s path=%q\n' "$role" "$digest" "$path"
}

public=$(type -P repro) || {
  echo 'setup-dev-env: cannot record Windows SDK: repro is absent from PATH' >&2
  exit 1
}
# Git Bash can resolve an executable without spelling its .exe suffix.
if [[ "$public" != *.exe && -f "$public.exe" ]]; then public="$public.exe"; fi
bin=$(cd "$(dirname "$public")" && pwd -P)
public="$bin/$(basename "$public")"
if [[ -n "${MCL_REPRO_BIN_DIR:-}" ]]; then
  expected=$(cd "$MCL_REPRO_BIN_DIR" && pwd -P)
  if [[ "$bin" != "$expected" ]]; then
    echo 'setup-dev-env: selected Windows SDK differs from repro on PATH' >&2
    exit 1
  fi
fi

printf 'setup-dev-env: windows-sdk-receipt v1 install-source=%q\n' "${MCL_REPRO_INSTALL_SOURCE:-unknown}"
fingerprint public-cli "$public"
fingerprint installed-engine "$bin/reprobuild.exe"
fingerprint installed-runquota-cli "$bin/runquota.exe"
fingerprint installed-runquota-daemon "$bin/runquotad.exe"
# These are shipped source markers, not an assertion about a compiler's
# selected source roots or a running daemon. Release/tag provenance remains
# the verified archive's existing checksum record.
fingerprint shipped-repro-config "$bin/../share/repro/source/config.nims"
fingerprint shipped-runquota-source "$bin/../share/repro/src/runquota/libs/runquota_core/src/runquota_core.nim"
if [[ -n "${RUNQUOTAD_BIN:-}" ]]; then
  fingerprint explicit-runquotad-override "$RUNQUOTAD_BIN"
elif [[ "${RUNQUOTAD_BIN+x}" == x ]]; then
  echo 'setup-dev-env: RUNQUOTAD_BIN=set-empty'
else
  echo 'setup-dev-env: RUNQUOTAD_BIN=unset'
fi

# Restrict observation to the legacy provisioning controls, never a general
# environment dump (which would include job credentials). Empty means set-empty.
found=false
# Prefix expansion works without the optional compgen builtin. A failed
# process-substitution producer must not turn a populated scan into "none".
for name in "${!WINDOWS_DIY_ENSURE_@}" "${!WINDOWS_DIY_SKIP_@}"; do
  [[ -n "$name" ]] || continue
  case "$name" in
    WINDOWS_DIY_SKIP_*|WINDOWS_DIY_ENSURE_*)
      printf 'setup-dev-env: inherited-bootstrap-control name=%s value=%q\n' "$name" "${!name}"
      found=true
      ;;
  esac
done
if [[ "$found" == false ]]; then
  echo 'setup-dev-env: inherited-bootstrap-controls=none'
fi

if [[ "${RUNNER_OS:-}" == Windows ]]; then
  pwsh -NoLogo -NoProfile -NonInteractive -File "$(dirname "$0")/record-runquota-peer.ps1"
fi
