#!/usr/bin/env bash
#
# decide-sibling-strategy.sh — pick WHICH mechanism provisions this repo's
# cross-repo siblings, and say so out loud.
#
# THE TWO MECHANISMS, AND WHY THE CHOICE WAS A FOOTGUN
# ----------------------------------------------------
# There are two, and until now a caller picked by hand:
#
#   clone-siblings  resolves each sibling from the WORKSPACE-PROJECT lock in
#                   metacraft-manifests. Those project manifests describe a
#                   repo SET convenient for a human setting up a workspace.
#                   They are typically a superset of what any one build needs,
#                   and they are not that build's source of truth.
#
#   repro develop   resolves each sibling from the consuming repo's OWN
#                   committed `repro.lock` — the solved dependency graph of
#                   the build itself, pinned to exact commit SHAs.
#
# Picking by hand went wrong in exactly the way an invisible choice does. A
# consumer hand-wrote nine siblings and routed them through `clone-siblings`;
# five were in its `repro.lock`, and four were a DEPENDENCY's siblings, not
# dependencies of the consumer at all. Nothing could ever pin those four,
# because nothing needed to — and the resulting hard failure took out every
# job on every pull request. The first attempted fix pinned all nine to a
# branch name, which cleared the error and silently un-pinned the four the
# lock had been pinning correctly.
#
# So this step decides, and the decision is REPORTED — one line to the log and
# one to the job summary, every run, on every path. The incident was an
# invisible resolution; a second invisible decision would be the same bug.
#
# WHAT `auto` WILL AND WILL NOT DO
# --------------------------------
# `auto` is deliberately conservative, because this action is consumed at
# `@main` by every repo in the org: a caller that passes nothing today must
# behave exactly as it does today. `auto` picks the repro path only when ALL
# of the following hold, and names the first one that fails otherwise:
#
#   1. `$GITHUB_WORKSPACE/repro.lock` exists and declares a solved-graph-lock
#      schema.
#   2. It pins at least one SIBLING dependency — a dep whose `path` is not
#      "." (the root/consumer entry). A root-only lock has nothing for
#      `repro develop --all` to provision, so routing to it would replace a
#      working clone step with a no-op.
#   3. `env-flavor` is `reprobuild`. The repro path needs the `repro` CLI, and
#      `reprobuild` is the one flavor where setup-dev-env is already going to
#      install it. Silently adding a from-source CLI build to every `nix` job
#      in the fleet is not something `auto` may do on its own; a caller that
#      wants it says `sibling-strategy: repro-lock` and pays for it knowingly.
#   4. The repo declares NO sibling set of its own — neither a non-empty
#      `siblings:` input nor a non-empty `.github/sibling-repos`. A caller
#      that hand-wrote a list is asserting something the lock does not know:
#      today several such lists name repos that are genuinely absent from the
#      repo's `repro.lock` (build-time siblings that are not solved-graph
#      dependencies). Switching those to the lock would drop them. The
#      declared list is therefore honoured, and the log says the lock was
#      available and was not used — never silently ignored.
#
# THIS IS ONLY THE STATIC HALF of the "is the lock usable" question. It reads
# the file, which is cheap and available before any tool is installed, and it
# is enough to route the composite. The AUTHORITATIVE check runs later in
# ./provision-siblings-from-lock.sh, against `repro develop --list --json`,
# once the CLI exists. If that check disagrees, `auto` falls back to
# clone-siblings there and says so; a forced `repro-lock` fails there.
#
# PORTABILITY. Pure bash builtins. No awk/sed/grep/coreutils and no
# associative arrays: this runs on GitHub's macOS images (bash 3.2) and on
# minimal self-hosted runners, and a guard must not need more than the thing
# it guards. Same rule as clone-siblings.sh.
#
# INPUTS arrive as environment variables set by the action's `env:` block.
set -euo pipefail

STRATEGY_INPUT="${SIBLING_STRATEGY:-auto}"
FLAVOR="${ENV_FLAVOR:-}"
WS="${GITHUB_WORKSPACE:-$PWD}"
LOCK="${WS}/repro.lock"
SIBS_FILE="${WS}/.github/sibling-repos"

case "${STRATEGY_INPUT}" in
auto | repro-lock | clone-siblings) ;;
*)
  echo "::error::setup-dev-env: 'sibling-strategy' must be one of: auto, repro-lock, clone-siblings (got '${STRATEGY_INPUT}')."
  exit 1
  ;;
esac

# ---------------------------------------------------------------------------
# Static evidence about the committed lock.
# ---------------------------------------------------------------------------
# LOCK_STATE is one of:
#   absent     — no file at $GITHUB_WORKSPACE/repro.lock
#   foreign    — a file is there but it does not declare a solved-graph-lock
#                schema, so it is not the artefact this path reads
#   root-only  — a solved-graph lock that pins no sibling dependency
#   usable     — a solved-graph lock pinning LOCK_SIBLINGS >= 1 siblings
LOCK_STATE="absent"
LOCK_SIBLINGS=0

if [ -f "${LOCK}" ]; then
  LOCK_STATE="foreign"
  _schema_ok=0
  while IFS= read -r _line || [ -n "${_line}" ]; do
    # Trim leading whitespace; the lock is TOML and the two keys we read are
    # written at column 0 today, but nothing in TOML requires that.
    _t="${_line#"${_line%%[![:space:]]*}"}"
    case "${_t}" in
    'schema = "reprobuild.solved-graph-lock.v'*)
      # Any solved-graph-lock schema version, not just v2. A version bump must
      # not silently demote every repo to clone-siblings; the CLI probe later
      # is what actually decides whether the lock can be read.
      _schema_ok=1
      ;;
    'deps = ['*)
      # One line, one array of inline tables. Count the entries whose `path`
      # is not "." — those are the siblings. `path = "."` is the consumer
      # itself and is not something to provision.
      _rest="${_t}"
      while :; do
        case "${_rest}" in
        *'path = "'*)
          _rest="${_rest#*path = \"}"
          _val="${_rest%%\"*}"
          if [ "${_val}" != "." ]; then
            LOCK_SIBLINGS=$((LOCK_SIBLINGS + 1))
          fi
          ;;
        *) break ;;
        esac
      done
      ;;
    esac
  done <"${LOCK}"

  if [ "${_schema_ok}" -eq 1 ]; then
    if [ "${LOCK_SIBLINGS}" -gt 0 ]; then
      LOCK_STATE="usable"
    else
      LOCK_STATE="root-only"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Does the repo declare a sibling set of its own?
# ---------------------------------------------------------------------------
# Mirrors clone-siblings.sh's own precedence exactly: a non-blank `siblings`
# input wins, otherwise `.github/sibling-repos` is read. Both accept '#'
# comments and whitespace/newline separation, so a comment-only file — which
# is what most repos in the fleet carry — declares nothing and does not count.
DECLARED=0
DECLARED_FROM=""
_raw=""
if [ -n "${SIBLINGS_INPUT//[[:space:]]/}" ]; then
  _raw="${SIBLINGS_INPUT}"
  DECLARED_FROM="the 'siblings' input"
elif [ -f "${SIBS_FILE}" ]; then
  _raw="$(<"${SIBS_FILE}")"
  DECLARED_FROM=".github/sibling-repos"
fi
if [ -n "${_raw}" ]; then
  while IFS= read -r _line || [ -n "${_line}" ]; do
    _line="${_line%$'\r'}"
    _line="${_line%%#*}"
    for _tok in ${_line}; do
      DECLARED=$((DECLARED + 1))
    done
  done <<<"${_raw}"
fi
[ "${DECLARED}" -eq 0 ] && DECLARED_FROM=""

# ---------------------------------------------------------------------------
# Decide.
# ---------------------------------------------------------------------------
STRATEGY=""
REASON=""

plural() { # <count> <singular> <plural>
  if [ "$1" -eq 1 ]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

lock_gap_reason() {
  case "${LOCK_STATE}" in
  absent) printf 'there is no repro.lock at %s' "${LOCK}" ;;
  foreign) printf '%s exists but declares no reprobuild.solved-graph-lock schema' "${LOCK}" ;;
  root-only) printf '%s pins no sibling dependency (every dep is path = ".", the consumer itself)' "${LOCK}" ;;
  *) printf 'the committed lock is usable' ;;
  esac
}

case "${STRATEGY_INPUT}" in
clone-siblings)
  STRATEGY="clone-siblings"
  REASON="forced by sibling-strategy: clone-siblings"
  ;;

repro-lock)
  # A forced override that quietly did nothing would be worse than no override
  # at all: the caller would believe it had switched paths and the job would go
  # on green, resolving from the manifests the caller was trying to stop using.
  if [ "${LOCK_STATE}" != "usable" ]; then
    {
      echo "::error::setup-dev-env: sibling-strategy: repro-lock was requested, but $(lock_gap_reason)."
      echo "  The repro path resolves siblings from the consuming repo's own committed"
      echo "  repro.lock. Without one there is nothing for it to read, and this action will"
      echo "  NOT quietly fall back to clone-siblings behind an explicit override — that is"
      echo "  the silent-resolution failure this input exists to make impossible."
      echo "  Either commit a repro.lock that pins this repo's dependency siblings, or use"
      echo "  sibling-strategy: auto (which would have chosen clone-siblings here) or"
      echo "  sibling-strategy: clone-siblings to say so deliberately."
    } >&2
    exit 1
  fi
  STRATEGY="repro-lock"
  REASON="forced by sibling-strategy: repro-lock; repro.lock pins ${LOCK_SIBLINGS} sibling $(plural "${LOCK_SIBLINGS}" dependency dependencies)"
  ;;

auto)
  if [ "${LOCK_STATE}" != "usable" ]; then
    STRATEGY="clone-siblings"
    REASON="$(lock_gap_reason)"
  elif [ "${FLAVOR}" != "reprobuild" ]; then
    STRATEGY="clone-siblings"
    REASON="repro.lock pins ${LOCK_SIBLINGS} $(plural "${LOCK_SIBLINGS}" sibling siblings), but env-flavor is '${FLAVOR}' and the repro path needs the repro CLI, which this action installs only for env-flavor: reprobuild; set sibling-strategy: repro-lock to install it anyway"
  elif [ "${DECLARED}" -gt 0 ]; then
    STRATEGY="clone-siblings"
    REASON="repro.lock pins ${LOCK_SIBLINGS} $(plural "${LOCK_SIBLINGS}" sibling siblings), but this repo declares ${DECLARED} of its own in ${DECLARED_FROM}; auto does not override a hand-declared list, because such lists routinely name build-time siblings the solved graph does not contain; set sibling-strategy: repro-lock to make the lock authoritative"
  else
    STRATEGY="repro-lock"
    REASON="repro.lock pins ${LOCK_SIBLINGS} sibling $(plural "${LOCK_SIBLINGS}" dependency dependencies) and this repo declares no sibling list of its own"
  fi
  ;;
esac

# ---------------------------------------------------------------------------
# Report. Every path, every run, one line.
# ---------------------------------------------------------------------------
LINE="setup-dev-env: sibling provisioning = ${STRATEGY} (${REASON})"
echo "${LINE}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'strategy=%s\n' "${STRATEGY}"
    printf 'reason=%s\n' "${REASON}"
    printf 'lock-state=%s\n' "${LOCK_STATE}"
    printf 'lock-siblings=%s\n' "${LOCK_SIBLINGS}"
    printf 'declared-siblings=%s\n' "${DECLARED}"
  } >>"${GITHUB_OUTPUT}"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### setup-dev-env: sibling provisioning\n\n'
    printf -- '- strategy: **%s** (sibling-strategy: `%s`)\n' "${STRATEGY}" "${STRATEGY_INPUT}"
    printf -- '- why: %s\n' "${REASON}"
  } >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
fi
