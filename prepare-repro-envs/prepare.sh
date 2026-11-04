#!/usr/bin/env bash
# Activate the same selected environment as the later build. Provider and
# bootstrap provisioning must succeed before the command witness can run.
# Partial optional developer tools retain the SDK's normal recovery semantics.
set -euo pipefail
if [[ -z ${REPRO_PREFLIGHT_PROJECTS//[[:space:]]/} ]]; then
  echo '::error::infrastructure preparation requires at least one project' >&2
  exit 2
fi
witness='prepare-repro-envs: activated command witness v1'
while IFS= read -r project || [[ -n $project ]]; do
  [[ -n $project ]] || continue
  if [[ ! -d $project ]]; then
    printf '::error::infrastructure preparation: missing project: %s\n' "$project" >&2
    exit 2
  fi
  printf 'preparing: %s\n' "$project"
  capture=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-preflight.XXXXXX")
  if repro exec "$project" -- bash -c 'printf "%s\n" "prepare-repro-envs: activated command witness v1"' > "$capture/stdout" 2> "$capture/stderr"; then
    status=0
  else
    status=$?
  fi
  output=$(<"$capture/stdout")
  cat "$capture/stdout"
  cat "$capture/stderr" >&2
  rm -rf "$capture"
  if [[ $status -ne 0 ]]; then
    printf '::error::infrastructure preparation: activation failed for %s (exit %s); SDK diagnostic above is the cause\n' "$project" "$status" >&2
    exit "$status"
  fi
  found=false
  while IFS= read -r line; do
    if [[ ${line%$'\r'} == "$witness" ]]; then found=true; fi
  done <<< "$output"
  if [[ $found != true ]]; then
    printf '::error::infrastructure preparation: %s returned success without executing its command witness\n' "$project" >&2
    exit 1
  fi
  printf 'prepared: %s\n' "$project"
done <<< "$REPRO_PREFLIGHT_PROJECTS"
