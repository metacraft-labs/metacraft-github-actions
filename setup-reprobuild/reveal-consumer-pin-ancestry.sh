#!/usr/bin/env bash
#
# reveal-consumer-pin-ancestry.sh -- when the Reprobuild source this action
# builds pins the CONSUMER itself as a sibling, deepen the consumer's shallow
# checkout until the engine can see that the pin is an ancestor of its HEAD.
# Nothing else is changed: not HEAD, not the working tree, not the job's
# environment.
#
# WHY
# ---
# An engine built from a Reprobuild git checkout (`.reprobuild-src`, the
# source route) judges every workspace sibling it compiles a recipe against
# by the revision that checkout pins for it (reprobuild
# `libs/repro_interface_artifacts`, `pinCheckedSiblingRoot` and
# `observeSiblingCheckout`, at 37a109c4). It anchors each `../<name>`
# candidate at the reprobuild checkout's parent AND at the consumer's parent,
# so a consumer whose directory carries a pinned name -- gosti at
# `/home/runner/work/gosti/gosti`, pinned by reprobuild's
# `.github/sibling-repos` as `gosti=cf435b3c...` -- is found as that sibling.
# The engine then asks
#
#     git -C <consumer> merge-base --is-ancestor <pin> HEAD
#
# with lazy fetching off. `actions/checkout` defaults to `fetch-depth: 1`,
# whose history is HEAD alone, so the question answers "no" even when the pin
# is seven commits behind HEAD, and the engine refuses the compile:
#
#     no acceptable source for GOSTI_SRC (gosti.nim): .../.reprobuild-src pins
#     'gosti' at cf435b3ca8ab..., but the sibling is at 71c8fd805e98, which is
#     not at or ahead of the revision cf435b3ca8ab this repository pins
#
# (gosti run 45782702955, Linux x64 and macOS). With the full history a
# developer's workspace has, the same consumer is accepted, which is what
# gosti's `fetch-depth: 0` stopgap showed. So this step supplies only the
# missing history, and the engine's own judgement stands: a consumer that is
# genuinely behind or off the pin's line is still refused, by the engine, in
# the engine's words.
#
# Building the source outside the workspace would not help: the engine also
# anchors candidates at the consumer's parent, so the consumer would still be
# found. Pointing `$<PKG>_SRC` at a separate clone of the pin would change
# what the consumer's own builds compile for the rest of the job.
#
# WHICH PIN
# ---------
# The one the engine reads (`pinnedSiblingRevisionIn`, reprobuild
# `libs/repro_core/src/repro_core/sibling_source_policy.nim`): the consumer's
# `deps` entry in `<source>/repro.lock`, else the single revision the direct
# root inputs of `<source>/flake.lock` lock for that repository, else a
# `<name>=<rev>` / `<name>!=<rev>` line of `<source>/.github/sibling-repos`.
# `<name>` is the consumer directory's own name, as the engine names a
# sibling by its directory. Only a full commit id is acted on; a branch value
# (`codetracer=dev`) is left to the engine.
#
# Bash builtins and git only, bash 3.2 compatible: like the provisioning step
# this runs before any toolchain is set up, and on the self-hosted macOS
# runners PATH has bash and git but no coreutils, sed or grep.
#
# Inputs (environment):
#   REPROBUILD_SOURCE_DIRECTORY  the selected Reprobuild checkout
#   MCL_CONSUMER_DIRECTORY / MCL_WORKSPACE_DIRECTORY  as for ci-roots/route.sh
#   REVEAL_DEEPEN_STEPS          optional, space-separated `--deepen` sizes
#                                tried before `--unshallow` (default below)
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"
[ "${HERE}" != "${BASH_SOURCE[0]}" ] || HERE="."
ACTIONS_ROOT="${GITHUB_ACTION_PATH:-${HERE}}/.."

# shellcheck source=../ci-roots/route.sh
. "${ACTIONS_ROOT}/ci-roots/route.sh" || exit 1
# shellcheck source=../reprobuild-provision/flake-lock-revisions.sh
. "${ACTIONS_ROOT}/reprobuild-provision/flake-lock-revisions.sh" || exit 1

say() { printf 'setup-reprobuild: %s\n' "$*"; }

SOURCE="${REPROBUILD_SOURCE_DIRECTORY:?REPROBUILD_SOURCE_DIRECTORY is required}"
SOURCE="${SOURCE//\\//}"
CONSUMER="${MCL_CONSUMER_ROOT//\\//}"
CONSUMER="${CONSUMER%/}"
NAME="${CONSUMER##*/}"

# `read_file <path>` -- the file's text, or nothing when it is absent.
read_file() {
  local line text=""
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    text+="${line%$'\r'}"$'\n'
  done <"$1"
  printf '%s' "${text}"
}

# `repro_lock_pin <name>` -- the revision of <name>'s `deps` entry, read as
# the engine reads it: the first `{ name = "<name>",` table whose
# `revision = "..."` field lies before that table's closing brace.
repro_lock_pin() {
  local text rest table key="{ name = \"$1\"," field='revision = "'
  text="$(read_file "${SOURCE}/repro.lock")"
  rest="${text}"
  while :; do
    case "${rest}" in *"${key}"*) ;; *) return 0 ;; esac
    rest="${rest#*"${key}"}"
    table="${rest%%\}*}"
    case "${table}" in
      *"${field}"*)
        table="${table#*"${field}"}"
        table="${table%%\"*}"
        if [ -n "${table}" ]; then
          printf '%s' "${table}"
          return 0
        fi
        ;;
    esac
  done
}

# `flake_lock_pin <name>` -- the one revision the root inputs of flake.lock
# lock for repository <name> (any owner), or nothing when there are none or
# several.
flake_lock_pin() {
  local want repo rev found=""
  [ -f "${SOURCE}/flake.lock" ] || return 0
  want="$(flake_lock_lowercase "$1")"
  while read -r repo _ rev; do
    [ "${repo}" = "${want}" ] || continue
    if [ -n "${found}" ] && [ "${found}" != "${rev}" ]; then
      return 0
    fi
    found="${rev}"
  done < <(flake_lock_revisions "${SOURCE}/flake.lock" 2>/dev/null)
  printf '%s' "${found}"
}

# `trim <text>` -- <text> without leading and trailing blanks.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# `sibling_repos_pin <name>` -- the value of the first `<name>!=` or
# `<name>=` line of .github/sibling-repos.
sibling_repos_pin() {
  local line head
  [ -f "${SOURCE}/.github/sibling-repos" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="$(trim "${line%$'\r'}")"
    case "${line}" in '' | '#'*) continue ;; esac
    case "${line}" in
      *'!='*)
        head="${line%%'!='*}"
        if [ -n "${head}" ] && [ "${head}" = "$1" ]; then
          trim "${line#*'!='}"
          return 0
        fi
        ;;
    esac
    case "${line}" in
      *=*)
        head="${line%%=*}"
        if [ -n "${head}" ] && [ "${head}" = "$1" ]; then
          trim "${line#*=}"
          return 0
        fi
        ;;
    esac
  done <"${SOURCE}/.github/sibling-repos"
}

pin="$(repro_lock_pin "${NAME}")"
[ -n "${pin}" ] || pin="$(flake_lock_pin "${NAME}")"
[ -n "${pin}" ] || pin="$(sibling_repos_pin "${NAME}")"

if [ -z "${pin}" ]; then
  # The ordinary case: the consumer is not one of the source's siblings.
  exit 0
fi
case "${pin}" in
  *[!0-9a-f]*)
    say "the Reprobuild source pins '${NAME}' at '${pin}', not a commit id; leaving the consumer checkout as it is."
    exit 0
    ;;
esac
if [ "${#pin}" -ne 40 ]; then
  say "the Reprobuild source pins '${NAME}' at '${pin}', not a full commit id; leaving the consumer checkout as it is."
  exit 0
fi

# The engine's question, asked the engine's way.
pin_is_ancestor() {
  GIT_NO_LAZY_FETCH=1 git -C "${CONSUMER}" merge-base --is-ancestor "${pin}" HEAD \
    >/dev/null 2>&1
}

if pin_is_ancestor; then
  say "the Reprobuild source pins the consumer '${NAME}' at ${pin}, which its checkout already shows to be an ancestor of HEAD."
  exit 0
fi
if [ "$(git -C "${CONSUMER}" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
  # Complete history: the engine's judgement of this checkout is final.
  say "the Reprobuild source pins the consumer '${NAME}' at ${pin}; its complete history does not reach it, so the engine will judge it as it stands."
  exit 0
fi
head="$(git -C "${CONSUMER}" rev-parse --verify HEAD 2>/dev/null)" || {
  say "cannot read the consumer's HEAD in ${CONSUMER}; leaving it as it is."
  exit 0
}

say "the Reprobuild source pins the consumer '${NAME}' at ${pin}; deepening its shallow checkout (HEAD ${head}) until that is visible as an ancestor."
# Fetch by commit id, so no ref of the consumer moves. The checkout's own
# credential configuration is used as is: it fetched this repository moments
# ago, and adding a second header for the same URL would be refused. A fetch
# that finds no credential fails instead of waiting on a prompt.
fetch() {
  GIT_TERMINAL_PROMPT=0 git -C "${CONSUMER}" -c protocol.version=2 fetch --quiet --no-tags \
    --no-recurse-submodules "$@" origin "${head}"
}
for depth in ${REVEAL_DEEPEN_STEPS:-16 128 1024}; do
  if ! fetch --deepen="${depth}"; then
    echo "::warning::setup-reprobuild: could not deepen ${CONSUMER} (see git's message above). The engine will refuse it as a sibling stale against ${pin}; check the consumer out with fetch-depth: 0 to work around this."
    exit 0
  fi
  if pin_is_ancestor; then
    say "${pin} is now visible as an ancestor of HEAD (deepened by ${depth})."
    exit 0
  fi
  if [ "$(git -C "${CONSUMER}" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
    break
  fi
done
if [ "$(git -C "${CONSUMER}" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  if ! fetch --unshallow; then
    echo "::warning::setup-reprobuild: could not fetch the rest of ${CONSUMER}'s history (see git's message above). The engine will refuse it as a sibling stale against ${pin}; check the consumer out with fetch-depth: 0 to work around this."
    exit 0
  fi
fi
if pin_is_ancestor; then
  say "${pin} is now visible as an ancestor of HEAD (complete history)."
  exit 0
fi
echo "::warning::setup-reprobuild: the Reprobuild source pins the consumer '${NAME}' at ${pin}, and the consumer's HEAD ${head} is not at or ahead of it even with its complete history. The engine will refuse it as a stale sibling: merge or rebase onto a revision that contains ${pin}, or set REPRO_SIBLING_POLICY=sibling to compile against the checkout as it is."
exit 0
