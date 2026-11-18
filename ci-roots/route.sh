#!/usr/bin/env bash
# Source in a child action. Literal defaults retain the original action behavior.
MCL_CONSUMER_ROOT=${GITHUB_WORKSPACE:?}
MCL_WORKSPACE_ROOT=$GITHUB_WORKSPACE
MCL_LEGACY_LAYOUT=true
if [[ ${MCL_CONSUMER_DIRECTORY:-.} != . || ${MCL_WORKSPACE_DIRECTORY:-.} != . ]]; then
  # Builtins only: the job PATH can be a Nix profile without coreutils, so
  # `dirname` may not resolve. Every caller sources this file by a path that
  # contains a slash (`${GITHUB_ACTION_PATH}/../ci-roots/route.sh`).
  mcl_roots=$(bash "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/resolve.sh") || return 1
  while IFS='=' read -r key value; do
    case $key in
      consumer-directory) MCL_CONSUMER_ROOT=$value ;;
      workspace-directory) MCL_WORKSPACE_ROOT=$value ;;
      legacy-layout) MCL_LEGACY_LAYOUT=$value ;;
    esac
  done <<< "$mcl_roots"
  unset mcl_roots
fi

export MCL_CONSUMER_ROOT MCL_WORKSPACE_ROOT MCL_LEGACY_LAYOUT
