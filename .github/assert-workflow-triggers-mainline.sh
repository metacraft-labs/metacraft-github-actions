#!/usr/bin/env bash
#
# assert-workflow-triggers-mainline.sh — every workflow's branch filters must
# name the branch the repository actually merges into.
#
# WHY THIS EXISTS
# ---------------
# A workflow whose `on: push: branches:` filter names a branch the repository
# does not have does not fail. It does nothing, silently, forever, and an empty
# check list on a mainline commit is indistinguishable from a clean one.
#
# That is not hypothetical. THIS repository's own `test.yml` said
# `branches: [main]` while its mainline was `dev`, so no push to the mainline
# of the shared-actions repo that 64 other repositories depend on had ever run
# a check. Two of the three guards sitting next to this file were added after a
# defect that reached all 64 consumers, and the second of those was itself
# pushed straight to the mainline past a suite that could have caught it —
# because of this exact line.
#
# A sweep of the workspace afterwards found the same defect in 33 workflows
# across 22 repositories, all from the same cause: repositories migrated off
# `main` to the class-specific mainline of branching-policy.md (product `dev`,
# spec `latest`, infra `live`, product-adapted forks the product-named branch)
# and their workflow triggers did not follow.
#
# WHAT IS CHECKED
# ---------------
# For every workflow file, for each of `push`, `pull_request` and
# `pull_request_target` that declares a `branches:` list: that list must contain
# the mainline, or a pattern matching it. Also rejected: a `branches-ignore:`
# that excludes the mainline, which reaches the same place by the other door.
#
# WHAT IS NOT CHECKED
# -------------------
# An event with no `branches:` filter is unrestricted and passes. An event
# filtered only by `tags:` is a release trigger, not a branch trigger, and
# passes — a publish workflow keyed on `v*` is correct as written and a guard
# that nagged about it would be a guard somebody switches off.
#
# DELIBERATELY-SCOPED WORKFLOWS
# -----------------------------
# Some workflows genuinely must not run on the mainline: a deploy that belongs
# to one environment branch, for instance. Say so in the file:
#
#     # ci-mainline-exempt: deploys web.example.com; `cloud` is the deploy branch
#
# The reason is mandatory — a bare marker is rejected — so the exemption is a
# decision somebody wrote down rather than a way to make the guard quiet.
#
# THE MAINLINE
# ------------
# Pass it as the first argument. With no argument it is detected from the
# branches that actually exist on `origin`, in branching-policy order: `dev`,
# then `latest`, then `live`. Detection deliberately has no `main` fallback: a
# repository that has not migrated has nothing for this guard to enforce, and
# guessing `main` would turn the guard into the very assumption it exists to
# catch. Forks whose mainline is a product name (`codetracer`, `isonim`) must
# pass it explicitly.
#
# Run:  bash .github/assert-workflow-triggers-mainline.sh [MAINLINE] [FILE...]
# File I/O needs Node 20/24 in the local development environment. The action
# supplies its declared runtime's actual executable via WORKFLOW_TRIGGERS_NODE.
set -euo pipefail

script_dir=${BASH_SOURCE[0]%/*}
if [ "$script_dir" = "${BASH_SOURCE[0]}" ]; then script_dir=.; fi
HERE="$(cd -- "$script_dir" && pwd)" || exit 2

# Normally the tree under test is this script's own repository. The Node
# action ships the guard from a DIFFERENT checkout than the one being checked,
# so it points this at the caller's workspace instead.
if [ -n "${WORKFLOW_TRIGGERS_ROOT-}" ]; then
  ROOT="$(cd -- "$WORKFLOW_TRIGGERS_ROOT" && pwd)" || exit 2
else
  ROOT="$(cd -- "$HERE/.." && pwd)" || exit 2
fi

MAINLINE="${1-}"
if [ "$#" -gt 0 ]; then shift; fi

if [ -z "$MAINLINE" ]; then
  MAINLINE="${WORKFLOW_MAINLINE_BRANCH-}"
fi

if [ -z "$MAINLINE" ]; then
  # Git is needed only for detection. Preserve its diagnostic and refuse even
  # a plausible partial listing when the command did not finish successfully.
  if heads="$(git -C "$ROOT" ls-remote --heads origin)"; then
    :
  else
    detection_status=$?
    echo "assert-workflow-triggers-mainline: could not list branches on origin (exit $detection_status)." >&2
    exit 2
  fi
  if [ -z "$heads" ]; then
    echo "assert-workflow-triggers-mainline: could not list branches on origin," >&2
    echo "  and no mainline was given. Pass it as the first argument." >&2
    echo "  Refusing to guess: guessing is the defect this guard exists to catch." >&2
    exit 2
  fi
  for candidate in dev latest live; do
    while IFS=$'\t' read -r _object ref; do
      if [ "$ref" = "refs/heads/$candidate" ]; then
        MAINLINE="$candidate"
        break
      fi
    done <<<"$heads"
    if [ -n "$MAINLINE" ]; then break; fi
  done
  if [ -z "$MAINLINE" ]; then
    echo "assert-workflow-triggers-mainline: no dev/latest/live branch on origin." >&2
    echo "  This repository has not migrated to branching-policy.md, so there is" >&2
    echo "  no mainline to enforce. Pass one explicitly if that is wrong." >&2
    exit 2
  fi
fi

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  # A process substitution hides its pipeline's status from the reader. Wait
  # for discovery to succeed before using any filenames: a failed traversal
  # can emit a valid subset, and checking that subset would be a false pass.
  # Keep stderr attached so an operational failure retains its actual cause.
  if workflow_files="$("${WORKFLOW_TRIGGERS_NODE:-node}" "$HERE/enumerate-workflows.cjs" "$ROOT/.github/workflows")"; then
    if [ -n "$workflow_files" ]; then
      while IFS= read -r f; do
        FILES+=("$f")
      done <<<"$workflow_files"
    fi
  else
    discovery_status=$?
    echo "assert-workflow-triggers-mainline: could not enumerate workflow files under $ROOT/.github/workflows (exit $discovery_status)." >&2
    exit 2
  fi
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "assert-workflow-triggers-mainline: no workflow files found under $ROOT/.github/workflows." >&2
  echo "  This guard has nothing to check, which is not the same as a pass." >&2
  exit 2
fi

rc=0
checked=0

# GitHub's filter globs: `*` does not cross `/`, `**` does, `?` is one
# character. Bash's `==` lets `*` cross `/`, which can only make this guard
# MORE permissive — it never invents a failure, it can only miss one — and no
# mainline in branching-policy.md contains a slash, so the difference is not
# reachable for the branch names this actually compares.
matches_mainline() { # <pattern>
  local pat="$1"
  [ "$pat" = "$MAINLINE" ] && return 0
  case "$pat" in
  *[\*\?\[]*)
    # shellcheck disable=SC2053 # glob on the right is the point
    [[ "$MAINLINE" == $pat ]] && return 0
    ;;
  esac
  return 1
}

# Strip a YAML scalar's surrounding quotes and any trailing comment.
unquote() { # <token>
  local t="$1"
  t="${t%"${t##*[![:space:]]}"}"
  t="${t#"${t%%[![:space:]]*}"}"
  case "$t" in
  \"*\") t="${t#\"}"; t="${t%\"}" ;;
  \'*\') t="${t#\'}"; t="${t%\'}" ;;
  esac
  printf '%s' "$t"
}

# Scan one workflow.
#
# The scan is line-based and anchored on INDENTATION, which is what keeps it
# from confusing the `on:` block with a `branches:` that appears in a step's
# `with:`. It tracks: whether we are inside the top-level `on:` mapping, which
# event we are under, and which filter key (`branches` / `branches-ignore` /
# `tags`) is currently open.
scan() { # <file> <complete contents>
  # Two statements, not one: bash expands every word of a `local` command
  # before it performs any of the assignments, so `local a="$1" b="${a}"`
  # reads the OUTER `a` — unset here, and fatal under `set -u`.
  local file="$1"
  local rel="${file#"$ROOT"/}"
  local line stripped indent
  local in_on=0 on_indent=-1
  local event="" event_indent=-1
  local filter="" filter_indent=-1

  # Per-event accumulators, kept as newline-separated text because bash 3.2
  # (the macOS default) has no associative arrays.
  local branches_seen="" ignore_seen="" tags_seen=""

  finish_event() {
    [ -z "$event" ] && return 0
    local pat ok=0
    if [ -n "$branches_seen" ]; then
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if matches_mainline "$pat"; then ok=1; fi
      done <<<"$branches_seen"
      if [ "$ok" -eq 0 ]; then
        echo "FAIL ${rel}: \`on: ${event}: branches:\` does not name the mainline \`${MAINLINE}\`."
        echo "     It lists: ${branches_seen//$'\n'/ }"
        echo "     A ${event} to \`${MAINLINE}\` therefore runs none of this workflow, and"
        echo "     an empty check list on a mainline commit looks exactly like a clean one."
        echo "     Add \`${MAINLINE}\` to the list. If this workflow genuinely must not run"
        echo "     on the mainline, say why in the file:"
        echo "       # ci-mainline-exempt: <reason>"
        rc=1
      fi
    elif [ -n "$ignore_seen" ]; then
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if matches_mainline "$pat"; then
          echo "FAIL ${rel}: \`on: ${event}: branches-ignore:\` excludes the mainline \`${MAINLINE}\`"
          echo "     via \`${pat}\`, so a ${event} to the mainline runs none of this workflow."
          rc=1
        fi
      done <<<"$ignore_seen"
    fi
    event="" branches_seen="" ignore_seen="" tags_seen=""
  }

  while IFS= read -r line || [ -n "$line" ]; do
    stripped="${line#"${line%%[![:space:]]*}"}"

    # Comments and blank lines carry no structure.
    case "$stripped" in
    '#'* | '') continue ;;
    esac
    indent=$((${#line} - ${#stripped}))

    # --- top-level structure -------------------------------------------
    if [ "$indent" -eq 0 ]; then
      finish_event
      filter="" filter_indent=-1
      case "$stripped" in
      on: | '"on":' | "'on':")
        in_on=1
        on_indent=0
        continue
        ;;
      on:* | '"on":'* | "'on':"*)
        # `on: push` or `on: [push, pull_request]` — no branch filters.
        in_on=0
        continue
        ;;
      *)
        in_on=0
        continue
        ;;
      esac
    fi

    [ "$in_on" -eq 1 ] || continue
    [ "$indent" -gt "$on_indent" ] || continue

    # --- event level ----------------------------------------------------
    if [ "$event_indent" -lt 0 ] || [ "$indent" -eq "$event_indent" ]; then
      case "$stripped" in
      push:* | pull_request:* | pull_request_target:*)
        finish_event
        filter="" filter_indent=-1
        event="${stripped%%:*}"
        event_indent="$indent"
        continue
        ;;
      *:*)
        if [ "$event_indent" -lt 0 ] || [ "$indent" -eq "$event_indent" ]; then
          finish_event
          filter="" filter_indent=-1
          [ "$event_indent" -lt 0 ] && event_indent="$indent"
          continue
        fi
        ;;
      esac
    fi

    [ -n "$event" ] || continue
    [ "$indent" -gt "$event_indent" ] || continue

    # --- filter level ---------------------------------------------------
    if [ -z "$filter" ] || [ "$indent" -le "$filter_indent" ]; then
      case "$stripped" in
      branches:* | branches-ignore:* | tags:* | tags-ignore:* | paths:* | paths-ignore:* | types:*)
        filter="${stripped%%:*}"
        filter_indent="$indent"
        local rest="${stripped#*:}"
        rest="$(unquote "$rest")"
        # Inline flow list, e.g. `branches: [main, dev]`.
        case "$rest" in
        \[*)
          rest="${rest#\[}"
          rest="${rest%%\]*}"
          local IFS=,
          local item
          for item in $rest; do
            item="$(unquote "$item")"
            [ -z "$item" ] && continue
            case "$filter" in
            branches) branches_seen+="${item}"$'\n' ;;
            branches-ignore) ignore_seen+="${item}"$'\n' ;;
            tags | tags-ignore) tags_seen+="${item}"$'\n' ;;
            esac
          done
          filter="" filter_indent=-1
          ;;
        "") : ;; # block list follows
        *)
          # Single inline scalar, e.g. `tags: 'v*'`.
          case "$filter" in
          branches) branches_seen+="${rest}"$'\n' ;;
          branches-ignore) ignore_seen+="${rest}"$'\n' ;;
          tags | tags-ignore) tags_seen+="${rest}"$'\n' ;;
          esac
          filter="" filter_indent=-1
          ;;
        esac
        continue
        ;;
      esac
    fi

    # --- block-list items under an open filter --------------------------
    if [ -n "$filter" ] && [ "$indent" -gt "$filter_indent" ]; then
      case "$stripped" in
      -*)
        local item="${stripped#-}"
        # Drop a trailing `# comment` on the item.
        case "$item" in
        *' #'*) item="${item%% #*}" ;;
        esac
        item="$(unquote "$item")"
        [ -z "$item" ] && continue
        case "$filter" in
        branches) branches_seen+="${item}"$'\n' ;;
        branches-ignore) ignore_seen+="${item}"$'\n' ;;
        tags | tags-ignore) tags_seen+="${item}"$'\n' ;;
        esac
        continue
        ;;
      esac
    fi
  done <<<"$2"
  finish_event
  return 0
}

# Read the whole file before either exemption checks or scanning. Bash read
# returns the same status for EOF and a read error, so reading the filesystem
# in its line loop can silently accept an empty or partially checked file.
# The declared Node runtime buffers the read and reports operational failures.
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "assert-workflow-triggers-mainline: no such file: $f" >&2
    exit 2
  fi
  rel="${f#"$ROOT"/}"
  if workflow="$("${WORKFLOW_TRIGGERS_NODE:-node}" "$HERE/read-workflow.cjs" "$f")"; then
    :
  else
    read_status=$?
    echo "assert-workflow-triggers-mainline: could not read workflow file $f (exit $read_status)." >&2
    exit 2
  fi

  exempt=0
  has_reason=0
  reason=""
  while IFS= read -r line || [ -n "$line" ]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
    '# ci-mainline-exempt:'*)
      value="${stripped#'# ci-mainline-exempt:'}"
      value="${value#"${value%%[![:space:]]*}"}"
      # Retain the first marker's text and the existing any-reason precedence.
      if [ "$exempt" -eq 0 ]; then reason="$value"; fi
      exempt=1
      if [ -n "$value" ]; then has_reason=1; fi
      ;;
    esac
  done <<<"$workflow"
  if [ "$has_reason" -eq 1 ]; then
    echo "skip ${rel}: exempt — ${reason}"
    checked=$((checked + 1))
    continue
  fi
  if [ "$exempt" -eq 1 ]; then
    echo "FAIL ${rel}: \`# ci-mainline-exempt:\` with no reason."
    echo "     An exemption without a reason is not a decision, it is a way to make"
    echo "     this guard quiet. Say what this workflow deploys or protects instead."
    rc=1
    checked=$((checked + 1))
    continue
  fi
  scan "$f" "$workflow"
  checked=$((checked + 1))
done

if [ "$rc" -eq 0 ]; then
  echo "assert-workflow-triggers-mainline: ${checked} workflow(s) name the mainline \`${MAINLINE}\`."
fi
exit "$rc"
