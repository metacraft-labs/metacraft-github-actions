#!/usr/bin/env bash
#
# provision-siblings-from-lock.sh — provision cross-repo siblings from the
# consuming repo's own committed `repro.lock`, via `repro develop`.
#
# WHAT THIS IS THE OTHER HALF OF
# ------------------------------
# ./decide-sibling-strategy.sh routes the composite from STATIC evidence (the
# lock file is present, declares a solved-graph-lock schema, and pins at least
# one sibling). That is enough to decide which branch of the action runs, and
# it is deliberately not enough to decide that the lock is USABLE — a file can
# exist and still name repos it does not pin, or hand its pins to a routed
# manifest store rather than to itself.
#
# The usable question is answered HERE, against evidence from the tool that
# owns the format:
#
#     repro develop --list --json
#
# which is read-only (it returns before any clone, fetch, override write or
# receipt), needs no network and no token, and reports for every repo WHICH
# BACKEND supplied its pin. This step accepts the lock only when all of:
#
#   * the CLI exits 0 and the document's own `exitCode` is 0;
#   * `schemaId` is `reprobuild.develop-list.v1` — an unknown schema means the
#     fields below are not the fields we think they are;
#   * `errors` is empty;
#   * a `committed-lock` backend is `reachable` with at least one record —
#     i.e. the repo's own repro.lock was actually read, not merely present;
#   * `repos` is non-empty;
#   * EVERY row's `backend` is `committed-lock`. A row pinned by a routed
#     `git-checkout` / `committed-file` / `git-notes` / `separate-branch` /
#     `external-cli` store is a pin from somewhere other than this repo's
#     committed lock, and claiming "the lock is authoritative" while some pins
#     come from elsewhere is the ambiguity this whole change removes;
#   * EVERY row's `revision` is a 40-hex commit SHA. This is the partial-lock
#     guard: a lock that names a dependency without pinning it to a commit
#     would otherwise pass every check above while provisioning nothing
#     reproducible.
#
# WHAT IT DOES NOT CLAIM. `repro develop --list` has no staleness signal, and
# there is no exit code for "this lock is older than the manifest" — the only
# command that answers that is `repro lock validate`, which re-solves and
# content-hashes every on-disk checkout. That is not a probe: it is slow and it
# reports an integrity mismatch for any sibling a developer has edited, so
# using it as a CI gate here would fail jobs for a reason that has nothing to
# do with sibling provisioning. Lock freshness is the REPO's contract, reported
# by its own `repro check`. What this step guarantees is narrower and honest:
# every sibling it provisions came from the committed lock, at an exact commit.
#
# WHEN THE EVIDENCE DOES NOT HOLD
# -------------------------------
#   sibling-strategy: auto        -> fall back to clone-siblings, loudly. The
#                                    caller asked for a decision, not for a
#                                    failure, and `auto` must never be the
#                                    reason a green fleet turns red.
#   sibling-strategy: repro-lock  -> fail. An explicit override that quietly
#                                    did something else is the footgun this
#                                    input exists to remove.
#
# THE `siblings:` INPUT UNDER THIS PATH
# -------------------------------------
# It is never silently ignored. Reaching this step with a declared list means
# the caller forced `repro-lock` (auto declines when a list is declared), so:
#
#   * an entry the lock already pins is REDUNDANT. The lock's revision wins —
#     that is what "the lock is authoritative" means — and the entry, plus any
#     `=ref` it carried, is reported as dropped, by name and by revision.
#   * an entry the lock does not name is ADDITIONAL. It cannot come from the
#     lock, so it is handed back to `clone-siblings` in a follow-on step and
#     reported as outside the lock. That is the honest answer for a repo
#     mid-migration whose build needs a sibling that is not yet a solved-graph
#     dependency.
#
# WHY NO `jq`. This runs on self-hosted runners as well as GitHub's images, and
# a JSON parser is not something a bash step may assume. The reader below is
# line-oriented against the exact pretty-printed shape `repro` emits, and it
# FAILS CLOSED: an output it cannot parse is "not usable", which routes to the
# fallback rather than to a wrong answer.
#
# PORTABILITY. Pure bash builtins plus `repro`. Bash 3.2-clean (GitHub's macOS
# images ship 3.2): no associative arrays, no `declare -n`, no coreutils, and
# no `${#arr[@]}` on a possibly-empty array under `set -u` — element counts are
# carried in plain integers instead. Same rule as clone-siblings.sh.
set -uo pipefail

STRATEGY_INPUT="${SIBLING_STRATEGY:-auto}"
SIBLINGS_INPUT="${SIBLINGS_INPUT:-}"
WS="${GITHUB_WORKSPACE:-$PWD}"
FORCED=0
[ "${STRATEGY_INPUT}" = "repro-lock" ] && FORCED=1

LATE_CLONE="false"
LATE_SIBLINGS=""

emit_outputs() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  {
    printf 'late-clone=%s\n' "${LATE_CLONE}"
    printf 'late-siblings<<__SETUP_DEV_ENV_EOF__\n'
    printf '%s\n' "${LATE_SIBLINGS}"
    printf '__SETUP_DEV_ENV_EOF__\n'
  } >>"${GITHUB_OUTPUT}"
}

summary() { # <line...>
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf -- '- %s\n' "$@" >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
}

# `not_usable <why>` — the single exit for "the committed lock did not hold up".
not_usable() {
  local why="$1"
  if [ "${FORCED}" -eq 1 ]; then
    {
      echo "::error::setup-dev-env: sibling-strategy: repro-lock was requested, but ${why}."
      echo "  This action will not silently fall back to clone-siblings behind an explicit"
      echo "  override. Fix the lock, or use sibling-strategy: auto (which falls back and"
      echo "  says so) or sibling-strategy: clone-siblings to choose the other path."
    } >&2
    echo "setup-dev-env: sibling provisioning = FAILED (forced repro-lock, but ${why})"
    summary "sibling provisioning: **failed** — forced \`repro-lock\`, but ${why}"
    emit_outputs
    exit 1
  fi
  echo "::warning::setup-dev-env: falling back to clone-siblings — ${why}."
  echo "setup-dev-env: sibling provisioning = clone-siblings (auto fell back: ${why})"
  summary "sibling provisioning: **clone-siblings** (auto fell back: ${why})"
  LATE_CLONE="true"
  LATE_SIBLINGS="${SIBLINGS_INPUT}"
  emit_outputs
  exit 0
}

# ---------------------------------------------------------------------------
# 1. Ask the tool that owns the format.
# ---------------------------------------------------------------------------
if ! command -v repro >/dev/null 2>&1; then
  not_usable "the 'repro' CLI is not on PATH, so the committed lock cannot be read"
fi

# stdout is the JSON document and stderr is not; merging them would hand the
# reader below a line it cannot place and turn a diagnosable failure into an
# unparseable one.
LIST_ERR="${RUNNER_TEMP:-/tmp}/setup-dev-env-develop-list.err"
LIST_OUT="$(cd "${WS}" && repro develop --list --json 2>"${LIST_ERR}")"
LIST_RC=$?

echo "::group::repro develop --list --json (exit ${LIST_RC})"
echo "${LIST_OUT}"
if [ -s "${LIST_ERR}" ]; then
  echo "--- stderr ---"
  printf '%s\n' "$(<"${LIST_ERR}")"
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. Read the document.
# ---------------------------------------------------------------------------
# `repro` pretty-prints it with one "key": value per line and a fixed indent
# step, so the levels are: 1 = a top-level key, 2 = an element's opening brace
# inside a top-level array, 3 = that element's own keys. The step is taken from
# the first indented line rather than assumed, so a formatter change from two
# spaces to four does not silently stop matching. Anything deeper is ignored,
# which is what makes a nested `"repos": []` inside a backend element harmless.
JS_SCHEMA_ID=""
JS_EXIT_CODE=""
JS_REPO_N=0
JS_BACKEND_N=0
JS_ERROR_N=0
JS_REPO_NAMES=()
JS_REPO_BACKENDS=()
JS_REPO_REVS=()
JS_BACKEND_KINDS=()
JS_BACKEND_REACHABLE=()
JS_BACKEND_RECORDS=()
JS_BACKEND_LOCATIONS=()
JS_ERRORS=()

json_read() { # <text>
  local line t indent unit=0 section="" key val
  local ridx=-1 bidx=-1 eidx=-1
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    t="${line#"${line%%[![:space:]]*}"}"
    [ -z "${t}" ] && continue
    indent=$((${#line} - ${#t}))
    t="${t%,}"
    if [ "${unit}" -eq 0 ] && [ "${indent}" -gt 0 ]; then unit="${indent}"; fi
    [ "${unit}" -eq 0 ] && continue

    key=""
    val=""
    case "${t}" in
    '"'*'": '*)
      key="${t#\"}"
      key="${key%%\"*}"
      val="${t#*\": }"
      case "${val}" in
      '"'*'"')
        val="${val#\"}"
        val="${val%\"}"
        ;;
      esac
      ;;
    esac

    if [ "${indent}" -eq "${unit}" ]; then
      case "${t}" in
      ']' | '}')
        section=""
        continue
        ;;
      '"'*'": [')
        # `"repos": [` opens a top-level array; `"notices": []` does not.
        section="${key}"
        continue
        ;;
      esac
      section=""
      case "${key}" in
      schemaId) JS_SCHEMA_ID="${val}" ;;
      exitCode) JS_EXIT_CODE="${val}" ;;
      esac
      continue
    fi

    if [ "${indent}" -eq $((unit * 2)) ]; then
      if [ "${t}" = "{" ]; then
        case "${section}" in
        repos)
          ridx=$((ridx + 1))
          JS_REPO_N=$((ridx + 1))
          JS_REPO_NAMES[ridx]=""
          JS_REPO_BACKENDS[ridx]=""
          JS_REPO_REVS[ridx]=""
          ;;
        backends)
          bidx=$((bidx + 1))
          JS_BACKEND_N=$((bidx + 1))
          JS_BACKEND_KINDS[bidx]=""
          JS_BACKEND_REACHABLE[bidx]=""
          JS_BACKEND_RECORDS[bidx]=""
          JS_BACKEND_LOCATIONS[bidx]=""
          ;;
        errors)
          eidx=$((eidx + 1))
          JS_ERROR_N=$((eidx + 1))
          JS_ERRORS[eidx]=""
          ;;
        esac
      fi
      continue
    fi

    if [ "${indent}" -eq $((unit * 3)) ]; then
      case "${section}" in
      repos)
        [ "${ridx}" -ge 0 ] || continue
        case "${key}" in
        name) JS_REPO_NAMES[ridx]="${val}" ;;
        backend) JS_REPO_BACKENDS[ridx]="${val}" ;;
        revision) JS_REPO_REVS[ridx]="${val}" ;;
        esac
        ;;
      backends)
        [ "${bidx}" -ge 0 ] || continue
        case "${key}" in
        kind) JS_BACKEND_KINDS[bidx]="${val}" ;;
        reachable) JS_BACKEND_REACHABLE[bidx]="${val}" ;;
        records) JS_BACKEND_RECORDS[bidx]="${val}" ;;
        location) JS_BACKEND_LOCATIONS[bidx]="${val}" ;;
        diagnostic) JS_BACKEND_LOCATIONS[bidx]="${JS_BACKEND_LOCATIONS[bidx]} — ${val}" ;;
        esac
        ;;
      errors)
        [ "${eidx}" -ge 0 ] || continue
        case "${key}" in
        diagnostic) JS_ERRORS[eidx]="${val}" ;;
        esac
        ;;
      esac
      continue
    fi
  done <<<"$1"
  return 0
}

json_read "${LIST_OUT}"

# ---------------------------------------------------------------------------
# 3. The evidence checks.
# ---------------------------------------------------------------------------
if [ -z "${JS_SCHEMA_ID}" ]; then
  not_usable "'repro develop --list --json' produced output this step could not read as a develop-list document (process exit ${LIST_RC})"
fi
if [ "${JS_SCHEMA_ID}" != "reprobuild.develop-list.v1" ]; then
  not_usable "'repro develop --list --json' reported schemaId '${JS_SCHEMA_ID}', not 'reprobuild.develop-list.v1'"
fi

# `repro`'s diagnostics are paragraphs, complete with escaped newlines, and the
# whole point of the one-line report is that it is one line. The full text is
# already in the `::group::` above; the summary carries the first sentence.
clip() { # <text>
  local t="$1"
  t="${t%%\\n*}"
  if [ "${#t}" -gt 200 ]; then
    t="${t:0:200}…"
  fi
  printf '%s' "${t}"
}

FIRST_ERROR=""
[ "${JS_ERROR_N}" -gt 0 ] && FIRST_ERROR="$(clip "${JS_ERRORS[0]}")"

if [ "${LIST_RC}" -ne 0 ] || [ "${JS_EXIT_CODE}" != "0" ]; then
  _diag=""
  [ -n "${FIRST_ERROR}" ] && _diag=": ${FIRST_ERROR}"
  not_usable "'repro develop --list --json' failed (process exit ${LIST_RC}, document exitCode ${JS_EXIT_CODE:-<none>})${_diag}"
fi
if [ "${JS_ERROR_N}" -gt 0 ]; then
  not_usable "'repro develop --list --json' reported ${JS_ERROR_N} error(s), the first being: ${FIRST_ERROR}"
fi

COMMITTED_LOCK_OK=0
COMMITTED_LOCK_WHERE=""
_i=0
while [ "${_i}" -lt "${JS_BACKEND_N}" ]; do
  if [ "${JS_BACKEND_KINDS[_i]}" = "committed-lock" ]; then
    COMMITTED_LOCK_WHERE="${JS_BACKEND_LOCATIONS[_i]}"
    if [ "${JS_BACKEND_REACHABLE[_i]}" = "true" ] &&
      [ -n "${JS_BACKEND_RECORDS[_i]}" ] && [ "${JS_BACKEND_RECORDS[_i]}" != "0" ]; then
      COMMITTED_LOCK_OK=1
    fi
  fi
  _i=$((_i + 1))
done
if [ "${COMMITTED_LOCK_OK}" -ne 1 ]; then
  not_usable "no reachable committed-lock backend contributed a record (${COMMITTED_LOCK_WHERE:-no committed-lock backend was reported at all})"
fi

if [ "${JS_REPO_N}" -eq 0 ]; then
  not_usable "the committed lock resolves to zero sibling repositories, so the repro path would provision nothing"
fi

is_sha40() { # <value>
  [ "${#1}" -eq 40 ] || return 1
  [ -z "${1//[0-9a-f]/}" ] || return 1
  return 0
}

_i=0
while [ "${_i}" -lt "${JS_REPO_N}" ]; do
  if [ "${JS_REPO_BACKENDS[_i]}" != "committed-lock" ]; then
    not_usable "'${JS_REPO_NAMES[_i]}' is pinned by the '${JS_REPO_BACKENDS[_i]}' backend, not by this repo's committed repro.lock"
  fi
  if ! is_sha40 "${JS_REPO_REVS[_i]}"; then
    not_usable "'${JS_REPO_NAMES[_i]}' is not pinned to a commit SHA by the committed lock (revision '${JS_REPO_REVS[_i]}')"
  fi
  _i=$((_i + 1))
done

# ---------------------------------------------------------------------------
# 4. Reconcile the caller's declared sibling list against the lock.
# ---------------------------------------------------------------------------
lock_rev_of() { # <name> -> prints the locked revision, or fails
  local i=0
  while [ "${i}" -lt "${JS_REPO_N}" ]; do
    if [ "${JS_REPO_NAMES[i]}" = "$1" ]; then
      printf '%s' "${JS_REPO_REVS[i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Same precedence as clone-siblings.sh: a non-blank `siblings` input wins,
# otherwise `.github/sibling-repos` is read.
DECLARED_RAW=""
DECLARED_FROM=""
if [ -n "${SIBLINGS_INPUT//[[:space:]]/}" ]; then
  DECLARED_RAW="${SIBLINGS_INPUT}"
  DECLARED_FROM="the 'siblings' input"
elif [ -f "${WS}/.github/sibling-repos" ]; then
  DECLARED_RAW="$(<"${WS}/.github/sibling-repos")"
  DECLARED_FROM=".github/sibling-repos"
fi

EXTRA=""
REDUNDANT=0
EXTRAS=0
if [ -n "${DECLARED_RAW}" ]; then
  while IFS= read -r _line || [ -n "${_line}" ]; do
    _line="${_line%$'\r'}"
    _line="${_line%%#*}"
    for _entry in ${_line}; do
      # `owner/name`, `name=ref`, `name!=ref` — reduce to the bare repo name.
      _name="${_entry%%=*}"
      _name="${_name%!}"
      _name="${_name##*/}"
      if _rev="$(lock_rev_of "${_name}")"; then
        REDUNDANT=$((REDUNDANT + 1))
        echo "::warning::setup-dev-env: '${_entry}' (from ${DECLARED_FROM}) is redundant under sibling-strategy: repro-lock — repro.lock pins ${_name} at ${_rev}, the lock is authoritative, and this entry is dropped."
        summary "\`${_entry}\` dropped: repro.lock pins \`${_name}\` at \`${_rev}\`"
      else
        EXTRAS=$((EXTRAS + 1))
        EXTRA="${EXTRA}${_entry}"$'\n'
        echo "::warning::setup-dev-env: '${_entry}' (from ${DECLARED_FROM}) is NOT in repro.lock, so the repro path cannot provide it; it is cloned additionally by clone-siblings, from the workspace-project lock."
        summary "\`${_entry}\` is outside repro.lock: cloned additionally via clone-siblings"
      fi
    done
  done <<<"${DECLARED_RAW}"
fi

# ---------------------------------------------------------------------------
# 5. Provision.
# ---------------------------------------------------------------------------
echo "::group::siblings resolved from ${COMMITTED_LOCK_WHERE}"
_i=0
while [ "${_i}" -lt "${JS_REPO_N}" ]; do
  printf '  %-32s %s  (%s)\n' "${JS_REPO_NAMES[_i]}" "${JS_REPO_REVS[_i]}" "${JS_REPO_BACKENDS[_i]}"
  _i=$((_i + 1))
done
echo "::endgroup::"

if ! (cd "${WS}" && repro develop --all); then
  {
    echo "::error::setup-dev-env: 'repro develop --all' failed after the committed lock had"
    echo "  been accepted as usable. This is NOT a resolution problem — every sibling above"
    echo "  is pinned to an exact commit by ${COMMITTED_LOCK_WHERE}. It is a clone/adopt"
    echo "  failure: a checkout already at that path pointing somewhere else, a drifted"
    echo "  working tree, or a repository the job's token cannot read. See the diagnostics"
    echo "  above."
  } >&2
  echo "setup-dev-env: sibling provisioning = FAILED (repro develop --all could not materialise the locked siblings)"
  summary "sibling provisioning: **failed** — \`repro develop --all\` could not materialise the locked siblings"
  emit_outputs
  exit 1
fi

REASON="repro.lock pinned ${JS_REPO_N} siblings at exact commits"
if [ "${REDUNDANT}" -gt 0 ]; then
  REASON="${REASON}; ${REDUNDANT} declared entries dropped as redundant"
fi
if [ "${EXTRAS}" -gt 0 ]; then
  REASON="${REASON}; ${EXTRAS} declared entries outside the lock handed to clone-siblings"
  LATE_CLONE="true"
  LATE_SIBLINGS="${EXTRA}"
fi

echo "setup-dev-env: sibling provisioning = repro-lock (${REASON})"
summary "sibling provisioning: **repro-lock** — ${REASON}"
emit_outputs
exit 0
