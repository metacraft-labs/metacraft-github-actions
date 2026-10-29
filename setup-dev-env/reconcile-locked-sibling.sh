#!/usr/bin/env bash
# Reconcile only clean, published CI siblings. Source this library; no globals.
# The lock remains authoritative; this never resets, removes or force-checks out.
locked_sibling_url() { # generated committed lock, selected name, exact revision
  local file=$1 name=$2 revision=$3 line deps="" entry body n r u found="" count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in 'deps = ['*) deps=${line#deps = [} ;; esac
  done <"$file"
  deps=${deps%]}
  # Same generated inline-table grammar used by clone-siblings' committed reader.
  while [ -n "$deps" ]; do
    case "$deps" in '{ '*' }'*) ;; *) return 1 ;; esac
    entry=${deps%%" }"*}; body=${entry#"{ "}
    deps=${deps#"$entry }"}; deps=${deps#", "}
    n=$(locked_sibling_field "$body" name) || return 1
    [ "$n" = "$name" ] || continue
    r=$(locked_sibling_field "$body" revision) || return 1
    [ "$r" = "$revision" ] || return 1
    u=$(locked_sibling_field "$body" url) || return 1
    count=$((count + 1)); found=$u
  done
  [ "$count" = 1 ] && [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
locked_sibling_field() {
  local body=", $1" key=$2 rest
  case "$body" in *", $key = \""*) ;; *) return 1 ;; esac
  rest=${body#*", $key = \""}; printf '%s' "${rest%%\"*}"
}
locked_sibling_identity() {
  local url=$1
  case "$url" in
    https://github.com/*) url=${url#https://github.com/} ;;
    ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
    git@github.com:*) url=${url#git@github.com:} ;;
    file:///*) printf '%s\n' "${url%/}"; return ;;
    *) return 1 ;;
  esac
  url=${url%/}; url=${url%.git}
  case "$url" in */*) ;; *) return 1 ;; esac
  case "$url" in *[!a-zA-Z0-9_./-]*|*../*|/*|*/*/*) return 1 ;; esac
  printf 'github.com/%s\n' "$url" | tr '[:upper:]' '[:lower:]'
}
reconcile_locked_sibling() { # consumer, selected name/revision, actual selected path
  local consumer=$1 name=$2 revision=$3 target=$4 parent scope physical origin expected head status
  [ -e "$target" ] || [ -L "$target" ] || return 0
  # Absent CI ownership means normal develop retains its existing refusal.
  [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${RUNNER_WORKSPACE:-}" ] || return 0
  consumer=$(cd "$consumer" && pwd -P) || return 1
  parent=$(cd "$consumer/.." && pwd -P) || return 1
  scope=$(cd "$RUNNER_WORKSPACE" && pwd -P) || return 1
  case "$parent/" in "$scope/"*) ;; *) return 1 ;; esac
  case "$name" in ''|.|..|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
  [ ! -L "$target" ] && [ -d "$target/.git" ] && [ ! -L "$target/.git" ] || return 1
  physical=$(cd "$target" && pwd -P) || return 1
  [ "$physical" = "$parent/$name" ] && [ "$physical" != "$consumer" ] || return 1
  [ "$(cd "$(git -C "$target" rev-parse --show-toplevel)" && pwd -P)" = "$physical" ] || return 1
  expected=$(locked_sibling_url "$consumer/repro.lock" "$name" "$revision") || return 1
  expected=$(locked_sibling_identity "$expected") || return 1
  origin=$(git -C "$target" remote get-url origin) || return 1
  origin=$(locked_sibling_identity "$origin") || return 1
  [ "$origin" = "$expected" ] || return 1
  status=$(git -C "$target" status --porcelain --untracked-files=all) || return 1
  [ -z "$status" ] || return 1
  head=$(git -C "$target" rev-parse --verify HEAD) || return 1
  [ "$head" != "$revision" ] || return 0
  # Refresh actual remote heads before proving publication; stale tracking refs
  # alone must not authorize moving a checkout containing unpublished work.
  scoped_git_auth_with_global git -c gc.auto=0 -c maintenance.auto=false -C "$target" fetch --prune --no-tags origin \
    '+refs/heads/*:refs/remotes/origin/*' || return 1
  [ -n "$(git -C "$target" for-each-ref --format='%(refname)' --contains="$head" refs/remotes/origin/)" ] || return 1
  git -C "$target" cat-file -e "$revision^{commit}" 2>/dev/null ||
    scoped_git_auth_with_global git -c gc.auto=0 -c maintenance.auto=false -C "$target" fetch --prune --no-tags origin "$revision" || return 1
  # Recheck after network operations. Never overwrite ignored-file collisions.
  [ "$(git -C "$target" rev-parse HEAD)" = "$head" ] || return 1
  [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ] || return 1
  git -C "$target" checkout --detach --no-overwrite-ignore "$revision"
}
