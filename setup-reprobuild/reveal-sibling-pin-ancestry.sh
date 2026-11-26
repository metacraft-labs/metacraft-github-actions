#!/usr/bin/env bash
#
# reveal-sibling-pin-ancestry.sh -- for every workspace sibling checkout that
# the Reprobuild source this job builds pins by commit (the consumer itself
# included), deepen a shallow checkout until the engine can see that the pin
# is an ancestor of its HEAD. Nothing else is changed: not HEAD, not any ref,
# not the working tree, not the job's environment.
#
# WHY
# ---
# An engine built from a Reprobuild git checkout (`.reprobuild-src`, the
# source route) judges every workspace sibling it compiles a recipe against
# by the revision that checkout pins for it (reprobuild
# `libs/repro_interface_artifacts`, `resolveSiblingFirstPackagePath`,
# `pinCheckedSiblingRoot` and `observeSiblingCheckout`, at 37a109c4), and the
# checkout's own `config.nims` judges its sibling-first packages the same way
# when it is built. For each sibling it asks
#
#     git -C <sibling> merge-base --is-ancestor <pin> HEAD
#
# with lazy fetching off. A depth-1 checkout's history is HEAD alone, so the
# question answers "no" even when the pin is a few commits behind HEAD, and
# the engine refuses the compile. Two shapes of this have been seen:
#
#   * the CONSUMER is the sibling. gosti run 45782702955: reprobuild's
#     `.github/sibling-repos` pins `gosti=cf435b3c...`, the engine anchors
#     `../gosti/src` at the consumer's parent too, finds the depth-1
#     `actions/checkout` of gosti, and refuses GOSTI_SRC although cf435b3c is
#     seven commits behind its HEAD;
#   * a sibling the workflow CLONED. io-mon runs 45869475954 and 45869479858
#     (io-mon `agents` 3bfa85d7): setup-dev-env's clone-siblings put
#     io-mon's own lock revision of nim-stackable-hooks, ec6b02d4, at
#     `../nim-stackable-hooks` with `--depth 1`; reprobuild 37a109c4's
#     repro.lock pins it at c34e3252, eleven commits behind ec6b02d4, and
#     `repro exec` stopped at
#
#       no acceptable source for STACKABLE_HOOKS_SRC (stackable_hooks.nim):
#       .../.reprobuild-src pins 'nim-stackable-hooks' at c34e3252..., but
#       the sibling is at ec6b02d45180, which is not at or ahead of the
#       revision c34e3252d413 this repository pins
#
# With the full history a developer's workspace has, both are accepted. So
# this step supplies only the missing history, and the engine's own judgement
# stands: a sibling that is genuinely behind or off the pin's line is still
# refused, by the engine, in the engine's words.
#
# WHERE THE SIBLINGS ARE
# ----------------------
# Where the engine looks for them (`bootstrapSiblingPackagePathFlagsFor`'s
# `workspaceRoots`): directly in the parent of the Reprobuild checkout (the
# workspace directory, where reprobuild-provision clones), in the parent of
# the consumer (where clone-siblings and setup-dev-env's repro.lock
# provisioning put them, and where the consumer itself sits), and in the
# parent of the working directory, which is the consumer here. A checkout is
# a directory with a `.git` entry; one inside the Reprobuild checkout is not
# a sibling.
#
# WHICH SIBLINGS
# --------------
# Only the directory names the engine (or the checkout's `config.nims`)
# judges against a pin; see JUDGED_SIBLINGS below. The source pins other
# repositories as well -- codetracer, nim, devops-modules -- whose sibling
# checkouts nothing judges, and deepening those (to the whole history of the
# Nim compiler, when the pin is off HEAD's line) would cost minutes and warn
# about a refusal that never comes.
#
# WHICH PIN
# ---------
# The one the engine reads (`pinnedSiblingRevisionIn`, reprobuild
# `libs/repro_core/src/repro_core/sibling_source_policy.nim`): the sibling's
# `deps` entry in `<source>/repro.lock`, else the single revision the direct
# root inputs of `<source>/flake.lock` lock for that repository, else a
# `<name>=<rev>` / `<name>!=<rev>` line of `<source>/.github/sibling-repos`.
# `<name>` is the checkout directory's own name, as the engine names a
# sibling by its directory. Only a full commit id is acted on; a branch value
# (`codetracer=dev`) is left to the engine.
#
# Bash builtins and git only, bash 3.2 compatible: like the provisioning step
# this runs before any toolchain is set up, and on the self-hosted macOS
# runners PATH has bash and git but no coreutils, sed or grep.
#
# Inputs (environment):
#   REPROBUILD_SOURCE_DIRECTORY  the selected Reprobuild checkout; nothing is
#                                done when it does not exist
#   MCL_CONSUMER_DIRECTORY / MCL_WORKSPACE_DIRECTORY  as for ci-roots/route.sh
#   REVEAL_DEEPEN_STEPS          optional, space-separated `--deepen` sizes
#                                tried before `--unshallow` (default below)
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"
[ "${HERE}" != "${BASH_SOURCE[0]}" ] || HERE="."
# This file lives in setup-reprobuild/, and setup-dev-env runs it from there
# too, so its own directory -- not the calling action's -- anchors the
# sibling scripts.
ACTIONS_ROOT="${HERE}/.."

# shellcheck source=../ci-roots/route.sh
. "${ACTIONS_ROOT}/ci-roots/route.sh" || exit 1
# shellcheck source=../reprobuild-provision/flake-lock-revisions.sh
. "${ACTIONS_ROOT}/reprobuild-provision/flake-lock-revisions.sh" || exit 1

say() { printf 'setup-reprobuild: %s\n' "$*"; }

# The sibling directories the engine judges against the source's pins, at
# reprobuild 37a109c4:
#   * `bootstrapSiblingPackagePathFlagsFor` (libs/repro_interface_artifacts):
#     every package whose candidate list names a checkout `../<name>` directly
#     in a workspace root, plus `../runquota` (`resolveRunquotaRoot`). The
#     `../codetracer/libs/<pkg>` candidates are nested in codetracer, not
#     checkouts of their own, and the CodeTracer seams are deliberately not
#     judged.
#   * `config.nims`'s `addSiblingFirstPackagePath`: nim-shm-queue,
#     nim-shm-gset, nim-cli-spec, nim-entrypoints and nim-confutils.
# The list is a copy of the engine's, so it is checked against the pinned
# source: check-judged-siblings.py, run by the `pins` workflow on every pin
# change, reads these names out of the engine and `config.nims` at the pin
# and fails when they differ from this list (or when the engine judges a
# sibling somewhere that check cannot read). Keep the assignment on this
# form, `JUDGED_SIBLINGS="..."`: the check reads it.
JUDGED_SIBLINGS="io-mon nim-stackable-hooks gosti runquota
  nim-shm-queue nim-shm-gset nim-cli-spec nim-entrypoints nim-confutils
  reprobuild-test-adapters nim-bearssl nimcrypto nim-stew nim-faststreams
  nim-serialization nim-json-serialization nim-toml-serialization
  nim-ssz-serialization"

SOURCE="${REPROBUILD_SOURCE_DIRECTORY:?REPROBUILD_SOURCE_DIRECTORY is required}"
SOURCE="${SOURCE//\\//}"
SOURCE="${SOURCE%/}"
if [ ! -d "${SOURCE}" ]; then
  # No source checkout: an installed engine judges no sibling by these pins.
  exit 0
fi
CONSUMER="${MCL_CONSUMER_ROOT//\\//}"
CONSUMER="${CONSUMER%/}"

# `read_file <path>` -- the file's text, or nothing when it is absent.
read_file() {
  local line text=""
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    text+="${line%$'\r'}"$'\n'
  done <"$1"
  printf '%s' "${text}"
}

# The three pin records, each read once.
REPRO_LOCK_TEXT="$(read_file "${SOURCE}/repro.lock")"
SIBLING_REPOS_TEXT="$(read_file "${SOURCE}/.github/sibling-repos")"
FLAKE_LOCK_REVISIONS=""
if [ -f "${SOURCE}/flake.lock" ]; then
  FLAKE_LOCK_REVISIONS="$(flake_lock_revisions "${SOURCE}/flake.lock" 2>/dev/null)"
fi

# `repro_lock_pin <name>` -- the revision of <name>'s `deps` entry, read as
# the engine reads it: the first `{ name = "<name>",` table whose
# `revision = "..."` field lies before that table's closing brace.
repro_lock_pin() {
  local rest table key="{ name = \"$1\"," field='revision = "'
  rest="${REPRO_LOCK_TEXT}"
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
  [ -n "${FLAKE_LOCK_REVISIONS}" ] || return 0
  want="$(flake_lock_lowercase "$1")"
  while read -r repo _ rev; do
    [ "${repo}" = "${want}" ] || continue
    if [ -n "${found}" ] && [ "${found}" != "${rev}" ]; then
      return 0
    fi
    found="${rev}"
  done <<<"${FLAKE_LOCK_REVISIONS}"
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
  [ -n "${SIBLING_REPOS_TEXT}" ] || return 0
  while IFS= read -r line; do
    line="$(trim "${line}")"
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
  done <<<"${SIBLING_REPOS_TEXT}"
}

# `pin_of <name>` -- the source's pin for <name>, in the engine's order.
pin_of() {
  local pin
  pin="$(repro_lock_pin "$1")"
  [ -n "${pin}" ] || pin="$(flake_lock_pin "$1")"
  [ -n "${pin}" ] || pin="$(sibling_repos_pin "$1")"
  printf '%s' "${pin}"
}

# `reveal <checkout> <name> <pin>` -- make <pin> visible as an ancestor of
# <checkout>'s HEAD if fetching more of its history can, and say what
# happened. Never fails: whatever is left unproven, the engine judges.
reveal() {
  local checkout="$1" name="$2" pin="$3" head depth what workaround
  if [ "${checkout}" = "${CONSUMER}" ]; then
    what="the consumer '${name}'"
    workaround="check the consumer out with fetch-depth: 0"
  else
    what="the sibling '${name}' (${checkout})"
    workaround="clone the sibling with its full history"
  fi

  # The engine's question, asked the engine's way.
  pin_is_ancestor() {
    GIT_NO_LAZY_FETCH=1 git -C "${checkout}" merge-base --is-ancestor "${pin}" HEAD \
      >/dev/null 2>&1
  }
  is_shallow() {
    [ "$(git -C "${checkout}" rev-parse --is-shallow-repository 2>/dev/null)" = true ]
  }
  # Fetch by commit id, so no ref moves. The checkout's own credential
  # configuration is used as is (`actions/checkout`'s persisted one in the
  # consumer, the job-scoped helper setup-dev-env installs for the others):
  # adding a second header for a URL that already has one would be refused.
  # A fetch that finds no credential fails instead of waiting on a prompt.
  fetch() {
    GIT_TERMINAL_PROMPT=0 git -C "${checkout}" -c protocol.version=2 fetch --quiet --no-tags \
      --no-recurse-submodules "$@" origin "${head}"
  }

  case "${pin}" in
    *[!0-9a-f]*)
      say "the Reprobuild source pins '${name}' at '${pin}', not a commit id; leaving ${what} as it is."
      return 0
      ;;
  esac
  if [ "${#pin}" -ne 40 ]; then
    say "the Reprobuild source pins '${name}' at '${pin}', not a full commit id; leaving ${what} as it is."
    return 0
  fi
  if pin_is_ancestor; then
    say "the Reprobuild source pins ${what} at ${pin}, which its checkout already shows to be an ancestor of HEAD."
    return 0
  fi
  if ! is_shallow; then
    # Complete history: the engine's judgement of this checkout is final.
    say "the Reprobuild source pins ${what} at ${pin}; its complete history does not reach it, so the engine will judge it as it stands."
    return 0
  fi
  head="$(git -C "${checkout}" rev-parse --verify HEAD 2>/dev/null)" || {
    say "cannot read the HEAD of ${what}; leaving it as it is."
    return 0
  }

  say "the Reprobuild source pins ${what} at ${pin}; deepening its shallow checkout (HEAD ${head}) until that is visible as an ancestor."
  for depth in ${REVEAL_DEEPEN_STEPS:-16 128 1024}; do
    if ! fetch --deepen="${depth}"; then
      echo "::warning::setup-reprobuild: could not deepen ${checkout} (see git's message above). The engine will refuse it as a sibling stale against ${pin}; ${workaround} to work around this."
      return 0
    fi
    if pin_is_ancestor; then
      say "${pin} is now visible as an ancestor of ${name}'s HEAD (deepened by ${depth})."
      return 0
    fi
    is_shallow || break
  done
  if is_shallow && ! fetch --unshallow; then
    echo "::warning::setup-reprobuild: could not fetch the rest of ${checkout}'s history (see git's message above). The engine will refuse it as a sibling stale against ${pin}; ${workaround} to work around this."
    return 0
  fi
  if pin_is_ancestor; then
    say "${pin} is now visible as an ancestor of ${name}'s HEAD (complete history)."
    return 0
  fi
  echo "::warning::setup-reprobuild: the Reprobuild source pins ${what} at ${pin}, and its HEAD ${head} is not at or ahead of it even with its complete history. The engine will refuse it as a stale sibling: move it to a revision that contains ${pin}, or set REPRO_SIBLING_POLICY=sibling to compile against the checkout as it is."
  return 0
}

# The workspace roots the engine anchors siblings at, each once: the
# source's parent (the workspace directory) and the consumer's parent (also
# the parent of the working directory `repro exec` runs in).
ROOTS=()
for root in "${SOURCE%/*}" "${CONSUMER%/*}"; do
  [ -n "${root}" ] && [ -d "${root}" ] || continue
  if [ "${#ROOTS[@]}" -gt 0 ] && [ "${ROOTS[0]}" = "${root}" ]; then
    continue
  fi
  ROOTS+=("${root}")
done
for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  for name in ${JUDGED_SIBLINGS}; do
    checkout="${root}/${name}"
    [ -e "${checkout}/.git" ] || continue
    # The Reprobuild checkout's own tree is not a sibling.
    case "${checkout}/" in "${SOURCE}/"*) continue ;; esac
    pin="$(pin_of "${name}")"
    # The ordinary case: the source does not pin this sibling.
    [ -n "${pin}" ] || continue
    reveal "${checkout}" "${name}" "${pin}"
  done
done
exit 0
