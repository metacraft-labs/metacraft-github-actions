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
locked_sibling_reason() { # constant category only; never configuration values
  printf 'setup-dev-env: locked sibling refusal reason=%s\n' "$1" >&2
}
locked_sibling_clean() { # root checkout; read-only, bounded path metadata
  local target=$1 status line count=0
  # Porcelain paths are relative to the repository root. Explicit Git quoting
  # keeps unusual names on one log line; never read a changed file's contents.
  if ! status=$(git -c core.quotePath=true -C "$target" status --porcelain --untracked-files=all 2>/dev/null); then
    locked_sibling_reason status-read
    return 1
  fi
  [ -n "$status" ] || return 0
  locked_sibling_reason local-work
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    if [ "$count" -le 10 ]; then
      # Omit an oversized quoted path whole rather than truncating an escape.
      if [ "${#line}" -le 512 ]; then
        printf 'setup-dev-env: locked sibling local-work: %s\n' "$line" >&2
      else
        printf 'setup-dev-env: locked sibling local-work: <path metadata omitted: longer than 512 characters>\n' >&2
      fi
    fi
  done <<<"$status"
  if [ "$count" -gt 10 ]; then
    printf 'setup-dev-env: locked sibling additional paths omitted: %s\n' "$((count - 10))" >&2
  fi
  return 1
}
reconcile_locked_sibling() { # consumer, selected name/revision, actual selected path
  local consumer=$1 name=$2 revision=$3 target=$4 parent scope physical origin expected head checkout_status
  [ -e "$target" ] || [ -L "$target" ] || return 0
  # Absent CI ownership means normal develop retains its existing refusal.
  [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${RUNNER_WORKSPACE:-}" ] || return 0
  consumer=$(cd "$consumer" && pwd -P) || { locked_sibling_reason consumer-path; return 1; }
  parent=$(cd "$consumer/.." && pwd -P) || { locked_sibling_reason consumer-parent; return 1; }
  scope=$(cd "$RUNNER_WORKSPACE" && pwd -P) || { locked_sibling_reason runner-path; return 1; }
  case "$parent/" in "$scope/"*) ;; *) locked_sibling_reason runner-scope; return 1 ;; esac
  case "$name" in ''|.|..|*[!a-zA-Z0-9_.-]*) locked_sibling_reason selected-name; return 1 ;; esac
  [ ! -L "$target" ] && [ -d "$target/.git" ] && [ ! -L "$target/.git" ] || { locked_sibling_reason checkout-layout; return 1; }
  physical=$(cd "$target" && pwd -P) || { locked_sibling_reason checkout-path; return 1; }
  [ "$physical" = "$parent/$name" ] && [ "$physical" != "$consumer" ] || { locked_sibling_reason checkout-location; return 1; }
  [ "$(cd "$(git -C "$target" rev-parse --show-toplevel)" && pwd -P)" = "$physical" ] || { locked_sibling_reason repository-root; return 1; }
  expected=$(locked_sibling_url "$consumer/repro.lock" "$name" "$revision") || { locked_sibling_reason lock-record; return 1; }
  expected=$(locked_sibling_identity "$expected") || { locked_sibling_reason lock-origin; return 1; }
  origin=$(git -C "$target" remote get-url origin) || { locked_sibling_reason origin-read; return 1; }
  origin=$(locked_sibling_identity "$origin") || { locked_sibling_reason origin-identity; return 1; }
  [ "$origin" = "$expected" ] || { locked_sibling_reason origin-mismatch; return 1; }
  locked_sibling_clean "$target" || return 1
  head=$(git -C "$target" rev-parse --verify HEAD) || { locked_sibling_reason head-read; return 1; }
  [ "$head" != "$revision" ] || return 0
  # Refresh actual remote heads before proving publication; stale tracking refs
  # alone must not authorize moving a checkout containing unpublished work.
  # This proof owns only the root repo. Historical child gitlinks may no longer
  # exist upstream; neither fetching proof nor checkout may operate on children.
  scoped_git_auth_with_global git -c gc.auto=0 -c maintenance.auto=false -C "$target" fetch --no-recurse-submodules --prune --no-tags origin \
    '+refs/heads/*:refs/remotes/origin/*' || { locked_sibling_reason publication-fetch; return 1; }
  [ -n "$(git -C "$target" for-each-ref --format='%(refname)' --contains="$head" refs/remotes/origin/)" ] || { locked_sibling_reason unpublished-head; return 1; }
  git -C "$target" cat-file -e "$revision^{commit}" 2>/dev/null ||
    scoped_git_auth_with_global git -c gc.auto=0 -c maintenance.auto=false -C "$target" fetch --no-recurse-submodules --prune --no-tags origin "$revision" || { locked_sibling_reason target-fetch; return 1; }
  # Recheck after network operations. Never overwrite ignored-file collisions.
  [ "$(git -C "$target" rev-parse HEAD)" = "$head" ] || { locked_sibling_reason head-changed; return 1; }
  locked_sibling_clean "$target" || return 1
  git -C "$target" checkout --no-recurse-submodules --detach --no-overwrite-ignore "$revision"
  checkout_status=$?
  if [ "$checkout_status" -ne 0 ]; then
    locked_sibling_reason checkout-refused
  fi
  return "$checkout_status"
}
