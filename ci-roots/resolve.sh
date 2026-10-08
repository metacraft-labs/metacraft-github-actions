#!/usr/bin/env bash
# Resolve explicit CI roots without changing GITHUB_WORKSPACE or attributing a
# checkout creator. The declared checkout app supplies worktree provenance.
set -euo pipefail
refuse() { printf '%s\n' "CI root refused: $1" >&2; exit 1; }
relative() {
  local value=$1
  [[ -n $value && $value != /* && $value != *:* && $value != *\\* && $value != *$'\n'* && $value != *$'\r'* ]] || refuse 'relative directory required'
  case /$value/ in */../*) refuse 'parent traversal';; esac
}
physical() {
  [[ -d $1 && ! -L $1 ]] || refuse 'regular directory required'
  (cd -- "$1" && pwd -P)
}
workspace=${GITHUB_WORKSPACE:?GITHUB_WORKSPACE required}
consumer_input=${MCL_CONSUMER_DIRECTORY:-.}
workspace_input=${MCL_WORKSPACE_DIRECTORY:-.}
relative "$consumer_input"
relative "$workspace_input"
physical_root=$(physical "$workspace")
consumer=$(physical "$workspace/$consumer_input")
containing=$(physical "$workspace/$workspace_input")
case "$consumer/" in "$physical_root/"*) ;; *) refuse 'consumer escaped physical workspace';; esac
case "$containing/" in "$physical_root/"*) ;; *) refuse 'workspace escaped physical workspace';; esac
legacy=false
if [[ $consumer_input == . && $workspace_input == . ]]; then
  legacy=true
else
  [[ $(physical "$consumer/..") == "$containing" ]] || refuse 'consumer parent differs from SDK workspace'
fi
git_image=$(command -v git)
[[ $git_image == /* && -f $git_image && -x $git_image ]] || refuse 'absolute Git executable required'
metadata_git() (
  # Child-only metadata authority; caller authentication/configuration survives.
  for key in ${!GIT_@}; do unset "$key"; done
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  "$git_image" "$@"
)
[[ $legacy == true || -n ${GITHUB_SHA:-} ]] || refuse 'opt-in event HEAD required'
[[ $(physical "$(metadata_git -C "$consumer" rev-parse --show-toplevel)") == "$consumer" ]] || refuse 'consumer Git root differs'
head=$(metadata_git -C "$consumer" rev-parse --verify HEAD)
[[ -z ${GITHUB_SHA:-} || $head == "$GITHUB_SHA" ]] || refuse 'consumer event HEAD differs'
# Preserve exact legacy output spelling. Opt-in paths use the validated relative
# inputs appended to the physical runner root, which PowerShell also accepts.
consumer_output=$workspace
workspace_output=$workspace
[[ $consumer_input == . ]] || consumer_output="$workspace/$consumer_input"
[[ $workspace_input == . ]] || workspace_output="$workspace/$workspace_input"
printf 'consumer-directory=%s\nworkspace-directory=%s\nlegacy-layout=%s\nconsumer-head=%s\n' "$consumer_output" "$workspace_output" "$legacy" "$head"
