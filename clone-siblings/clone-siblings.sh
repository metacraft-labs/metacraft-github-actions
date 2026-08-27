#!/usr/bin/env bash
#
# clone-siblings.sh — the body of the `clone-siblings` composite action.
#
# WHY THIS IS A FILE AND NOT A `run:` BLOCK
# -----------------------------------------
# It used to be the `run:` block in ../clone-siblings/action.yml. A composite
# action's `run:` body is a TEMPLATE STRING, and GitHub's parser refuses one
# past a length limit — at which point the consumer's job never starts and the
# diagnostic names a file in THIS repo from inside somebody else's run. That
# happened on 2026-08-26 and took the mainline CI of every repo in the org down
# at once; `.github/assert-composite-run-size.sh` is the guard written after it,
# and its header prescribes exactly this remedy:
#
#     run: bash "${GITHUB_ACTION_PATH}/clone-siblings.sh"
#
# The body had 76 characters of headroom left against that budget, which is not
# enough to add a line of code, let alone the rationale for one. A script file
# has no template limit, is shellcheckable, and can be executed directly by
# ./clone-siblings-step-test.sh instead of being scraped out of YAML.
#
# INPUTS arrive as environment variables set by the action's `env:` block; see
# action.yml for what each one is and what its input is called. The five values
# that were `${{ }}` expressions are now: $GITHUB_ACTION_PATH, $GITHUB_SHA and
# $GITHUB_EVENT_NAME (runner builtins) plus $PR_BASE_SHA and $EVENT_BEFORE
# (passed through `env:`, because the runner exposes no builtin for either).
#
# PORTABILITY. Pure bash builtins plus `git`. No awk/sed/grep/coreutils: this
# step executes in the consumer's dev-env shell, which may be a minimal Nix bash
# with nothing else on PATH. Bash 3.2-clean — GitHub's macOS runner images ship
# 3.2, so no associative arrays and no `declare -n`.
set -euo pipefail

RESOLVER="${GITHUB_ACTION_PATH}/resolve-sibling-rev.sh"
MANIFESTS_REF="${INPUT_MANIFESTS_REF:-${MANIFESTS_REF:-latest}}"
PRIVATE_MANIFESTS_REF="${INPUT_PRIVATE_MANIFESTS_REF:-${MANIFESTS_REF}}"

case "${ON_LOCK_OVERRIDE:=warn}" in
warn | error) ;;
*)
  echo "::error::clone-siblings: 'on-lock-override' must be 'warn' or 'error' (got '${ON_LOCK_OVERRIDE}')."
  exit 1
  ;;
esac

# The explicit `siblings` input (if provided) overrides the repo-level
# `.github/sibling-repos` declaration; otherwise read the file. Both accept
# '#' comments and whitespace/newline separation.
if [ -n "${SIBLINGS_INPUT//[[:space:]]/}" ]; then
  RAW="${SIBLINGS_INPUT}"
else
  SIBS_FILE="${GITHUB_WORKSPACE}/.github/sibling-repos"
  if [ ! -f "${SIBS_FILE}" ]; then
    echo "No 'siblings' input and no .github/sibling-repos; no cross-repo siblings to clone."
    exit 0
  fi
  RAW="$(<"${SIBS_FILE}")"
fi
SIBLINGS=()
# On Windows, `actions/checkout@v4` respects git's `core.autocrlf=true` default
# and converts LF-in-repo to CRLF-in-worktree. With `IFS= read -r`, that
# trailing `\r` sticks to the last token on each line, and downstream
# comparisons (lock lookups, path lookups) then miss because the CR is a literal
# part of the value. Strip any `\r` per line before tokenising.
while IFS= read -r _line || [ -n "${_line}" ]; do
  _line="${_line%$'\r'}"
  _line="${_line%%#*}"
  for _tok in ${_line}; do
    # `_tok` inherits the CRLF too when the trailing CR was before a `#`
    # comment marker (rare); belt-and-braces trim.
    _tok="${_tok%$'\r'}"
    SIBLINGS+=("${_tok}")
  done
done <<<"${RAW}"
if [ "${#SIBLINGS[@]}" -eq 0 ]; then
  echo "No cross-repo siblings to clone."
  exit 0
fi

SELF="${GITHUB_REPOSITORY##*/}"

# ---------------------------------------------------------------------------
# Split entries into owner + name + optional explicit ref.
#
# An entry is `[owner/]name[!]=[ref]`. The owner half is optional and defaults
# to `sibling-owner`; the NAME half is the workspace-lock key and the directory
# the clone lands in, so `owner/` is stripped before either is used. The `=ref`
# split happens FIRST because a ref may itself contain `/` (a branch name),
# which would otherwise be mistaken for an owner separator.
#
# The `!` in `name!=ref` marks an override of a workspace-lock pin as
# DELIBERATE; see the override section below for why that acknowledgement is
# per-entry and not a single action-level switch. It is stripped only when there
# actually is an `=`: a trailing `!` on a bare entry is a typo, and left alone it
# would become a clone of a repository named `name!` — a 404 on a private repo,
# diagnosed several steps later as a wrong name.
# First word only; see the `sibling-owner` input description.
for _w in ${SIBLING_OWNER}; do
  DEFAULT_OWNER="${_w}"
  break
done
DEFAULT_OWNER="${DEFAULT_OWNER:-}"

NAMES=()
REFS=()
OWNERS=()
ACKED=()
NEED_LOCK=0
for entry in "${SIBLINGS[@]}"; do
  rf=""
  ack=0
  case "${entry}" in
  *=*)
    spec="${entry%%=*}"
    rf="${entry#*=}"
    case "${spec}" in
    *'!')
      ack=1
      spec="${spec%'!'}"
      ;;
    esac
    ;;
  *) spec="${entry}" ;;
  esac
  case "${spec}" in
  */*)
    ow="${spec%%/*}"
    nm="${spec#*/}"
    ;;
  *)
    ow="${DEFAULT_OWNER}"
    nm="${spec}"
    ;;
  esac
  case "${nm}" in
  */*)
    echo "::error::sibling entry '${entry}' has more than one '/'; the form is [owner/]name[!]=[ref]."
    exit 1
    ;;
  esac
  case "${nm}" in
  *'!'*)
    echo "::error::sibling entry '${entry}' has a '!' in the repository name. The only place '!' is meaningful is immediately before the '=' of an explicit ref: 'name!=ref' means 'yes, I mean this override of the workspace-lock pin'."
    exit 1
    ;;
  esac
  if [ -z "${nm}" ]; then
    echo "::error::sibling entry '${entry}' has an empty repository name; the form is [owner/]name[!]=[ref]."
    exit 1
  fi
  NAMES+=("${nm}")
  REFS+=("${rf}")
  OWNERS+=("${ow}")
  ACKED+=("${ack}")
  [ -z "${rf}" ] && NEED_LOCK=1
done

# ---------------------------------------------------------------------------
# An explicit `name=ref` override is a REVISION, and it was the one revision in
# this action nothing checked.
#
# `resolve-sibling-rev.sh` shape-checks every revision it reads out of a lock
# (its `check_rev_shape`), for two reasons that are on the record. A value like
# `main` makes CI build a branch TIP, which is the silent, unpinned resolve this
# whole mechanism exists to prevent. And a value starting with `-` is not a
# refspec at all: this step substitutes it into `git fetch <remote> <rev>`, git
# parses options AFTER the remote, and `--upload-pack=<cmd>` is handed to
# `sh -c` — command execution on the runner, after which the fetch SUCCEEDS and
# the step goes green.
#
# The override path reached `git fetch` without passing through any of that,
# because it never goes near the resolver. Same substitution, same git, so it
# gets the same standard.
#
# The check is a whitelist over the characters a branch, tag or SHA can contain,
# which is deliberately narrower than `git check-ref-format`: everything this org
# actually passes today (`main`, `mcr-backend-integration`, `refs/heads/dev`, a
# 40-hex SHA) is inside it, and everything that makes git do something other than
# name a revision — a leading `-`, whitespace, `;`, `$`, `:`, `~`, `^`, `?`, `*`,
# `[`, `\` — is outside it.
ref_shape_ok() { # <ref>
  local r="$1" i=0 c
  [ -n "${r}" ] || return 1
  case "${r}" in
  -* | .* | /*) return 1 ;;
  */ | *.) return 1 ;;
  *..* | *//* | *@\{*) return 1 ;;
  *.lock) return 1 ;;
  esac
  while [ "${i}" -lt "${#r}" ]; do
    c="${r:${i}:1}"
    case "${c}" in
    [0-9A-Za-z._/-]) ;;
    *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

is_sha40() { # <rev>
  local r="$1" i=0 c
  [ "${#r}" -eq 40 ] || return 1
  while [ "${i}" -lt 40 ]; do
    c="${r:${i}:1}"
    case "${c}" in
    [0-9a-f]) ;;
    *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Validated before ANYTHING is cloned — including the manifests repo — so a
# hostile or malformed entry costs no network and leaves no half-populated
# workspace parent behind. Whether an override is REPRODUCIBLE is a separate
# question that needs the lock to answer, so it is asked in PASS 1 below.
BAD_REFS=""
for i in "${!NAMES[@]}"; do
  [ -z "${REFS[$i]}" ] && continue
  ref_shape_ok "${REFS[$i]}" || BAD_REFS="${BAD_REFS} ${NAMES[$i]}=${REFS[$i]}"
done
if [ -n "${BAD_REFS}" ]; then
  echo "::error::refusing sibling override(s) whose revision is not a usable ref:${BAD_REFS}"
  echo "::error::An override revision is substituted into 'git fetch <remote> <rev>'. git parses options after the remote, so a value beginning with '-' is an OPTION, and '--upload-pack=<cmd>' executes <cmd> on this runner. A revision must be a plain branch name, tag or 40-hex commit SHA: [0-9A-Za-z._/-] only, not starting with '-', '.' or '/'."
  exit 1
fi

# ---------------------------------------------------------------------------
# The git credential for everything this step clones.
#
# This used to be a token embedded in every clone URL plus, in each sibling's own
# `.git/config`, a catch-all `url.<credentialed github.com>.insteadOf` covering
# the whole of github.com. That left a live App token in the `.git/config` of
# every sibling clone and every submodule of every sibling clone — files that sit
# next to the workspace, get archived as artifacts, and on this org's self-hosted
# runners survive into the next job — and it authenticated every github.com fetch
# those clones ever made, third parties included. A URL-borne credential is also
# the one shape git hands to `credential approve` on success, so on a runner with
# a `credential.helper` it was additionally written to `~/.git-credentials`.
#
# It is now an `http.https://github.com/<owner>/.extraHeader` in THIS STEP's
# process environment. Child processes inherit it (including `git submodule
# update --recursive`, at every depth); nothing else does, and nothing writes it
# down.
#
# THE SCOPE IS DERIVED, not configured: it is the exact set of owners this step
# is about to clone from — every sibling's owner plus the owners of the manifest
# repos. A sibling this action can name is therefore a sibling this action can
# authenticate, by construction.
# shellcheck source=../git-auth/scoped-git-auth.sh
. "${GIT_AUTH_DIR}/scoped-git-auth.sh"

CLONE_OWNERS=()
add_owner() {
  local o="$1" e
  [ -z "${o}" ] && return 0
  for e in ${CLONE_OWNERS[@]+"${CLONE_OWNERS[@]}"}; do
    [ "${e}" = "${o}" ] && return 0
  done
  CLONE_OWNERS+=("${o}")
}
for ow in ${OWNERS[@]+"${OWNERS[@]}"}; do add_owner "${ow}"; done
# The manifest owners are added unconditionally, because the lock is now
# consulted for EVERY entry and not only for the bare ones. See "WHY THE LOCK IS
# READ EVEN WHEN NOTHING RESOLVES FROM IT" below.
add_owner "$(scoped_git_auth_owner_of "${MANIFESTS_REPO}")"
if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
  add_owner "$(scoped_git_auth_owner_of "${PRIVATE_MANIFESTS_REPO}")"
fi

if [ "${#CLONE_OWNERS[@]}" -eq 0 ]; then
  echo "::error::no GitHub owner to clone from: 'sibling-owner' is empty and no sibling entry is spelled owner/name."
  exit 1
fi

export TOKEN_OWNERS="${CLONE_OWNERS[*]}"
export SCOPED_GIT_AUTH_REWRITES=1
export SCOPED_GIT_AUTH_MASK=1
scoped_git_auth_build
scoped_git_auth_export
scoped_git_auth_report

# ---------------------------------------------------------------------------
# The coupling this action used to hide.
#
# The sibling owner was hard-coded to `metacraft-labs` here while `setup-nix`'s
# `token-owner` defaulted to the same string in a different file. Nothing tied
# them together, and while the CI token authenticated all of github.com nothing
# had to: a mismatch simply worked. It no longer does — an owner outside
# `setup-nix`'s scope gets a 404 on a private repo, which reads as a wrong
# repository name — so the disagreement is detected here, by name, before
# anything is cloned.
if [ -n "${JOB_TOKEN_OWNERS//[[:space:]]/}" ]; then
  TOKEN_OWNERS="${JOB_TOKEN_OWNERS}" \
    scoped_git_auth_require_covered "clone-siblings" \
    ${CLONE_OWNERS[@]+"${CLONE_OWNERS[@]}"} || exit 1
fi

# ---------------------------------------------------------------------------
# WHY THE LOCK IS READ EVEN WHEN NOTHING RESOLVES FROM IT
#
# The manifest repo used to be cloned only when at least one entry was bare
# (`NEED_LOCK`). That made the most dangerous sibling list in existence — one
# where EVERY entry carries an explicit `=ref` — the one list this action never
# checked against anything: it could not know that four of those refs were
# replacing revisions the lock was pinning correctly, because it never looked at
# the lock. That is not hypothetical. It is what a proposed fix to
# `codetracer`'s isonim siblings would have done: pin all nine to `=dev`, of
# which four were already, correctly, pinned by the lock. CI would have gone on
# passing while those four silently became moving branch tips.
#
# So the lock is now read whenever there is anything to clone. What `NEED_LOCK`
# still decides is whether it is REQUIRED: a bare entry has no other source of a
# revision, so for it a missing or unreadable lock is fatal exactly as before.
# When every entry is explicit the lock is advisory — it is consulted to detect
# overrides, and if it cannot be read the step says so and continues, because it
# would have continued without even trying before this change.
#
# MANIFEST LAYERS. `LAYER_ARGS` accumulates one `--manifest-dir` per layer,
# least specific FIRST — the order is the resolver's precedence order
# (reprobuild-specs/Workspace-And-Develop-Mode.md §"Layering Rules": a repo
# declared in several layers is deduplicated with the more specific layer taking
# precedence). With no `private-manifests-repo` this is a one-element list, i.e.
# byte-for-byte the single-layer resolve every consumer already gets.
MAN=""
LOCK_SHA=""
LAYER_ARGS=()

lock_unavailable() { # <reason>
  # Fatal when something has to resolve FROM the lock; otherwise the override
  # check is the only casualty, and losing it must not fail a job that never
  # asked the lock for anything.
  if [ "${NEED_LOCK}" -eq 1 ]; then
    echo "::error::$1"
    exit 1
  fi
  echo "::warning::$1 Every sibling in this list carries an explicit ref, so nothing needed a revision FROM the lock and the clones proceed — but this run cannot tell you whether any of those refs is replacing a revision the lock pins."
  LAYER_ARGS=()
}

MAN="${RUNNER_TEMP}/metacraft-manifests"
rm -rf "${MAN}"
# Credential-free URL. Authentication rides the scoped extraHeader installed
# above, which covers this repo's owner because the scope was derived from
# `manifests-repo` itself.
MAN_URL="https://github.com/${MANIFESTS_REPO}.git"
echo "Cloning manifests repo on branch '${MANIFESTS_REF}'..."
if ! git clone --depth 1 --branch "${MANIFESTS_REF}" "${MAN_URL}" "${MAN}"; then
  lock_unavailable "Failed to clone manifests repo from ${MAN_URL} on branch ${MANIFESTS_REF}."
else
  LAYER_ARGS+=(--manifest-dir "${MAN}")

  # The org/team-private layer, when the caller declares one. It is cloned with
  # the SAME token — a private manifest repo is access-controlled by definition,
  # so a failure to clone it is never a silent downgrade to the public layer:
  # that would resolve private siblings to whatever the public layer happens to
  # say, or fail much later with a misleading diagnostic. When the lock is only
  # advisory the whole check is dropped rather than run against half the layers,
  # for the same reason: a partial layer set can report an override that is not
  # one, or miss one that is.
  if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
    PRIV_MAN="${RUNNER_TEMP}/metacraft-manifests-private"
    rm -rf "${PRIV_MAN}"
    PRIV_URL="https://github.com/${PRIVATE_MANIFESTS_REPO}.git"
    echo "Cloning PRIVATE manifests repo on branch '${PRIVATE_MANIFESTS_REF}'..."
    if ! git clone --depth 1 --branch "${PRIVATE_MANIFESTS_REF}" "${PRIV_URL}" "${PRIV_MAN}"; then
      lock_unavailable "Failed to clone the private manifests repo ${PRIVATE_MANIFESTS_REPO} on branch ${PRIVATE_MANIFESTS_REF}. A private manifest layer was declared, so resolving siblings from the public layer alone would silently drop every pin the private layer owns. Check that the CI App token has read access to it."
    else
      LAYER_ARGS+=(--manifest-dir "${PRIV_MAN}")
    fi
  fi
fi

# Which commit's lock to use; `--no-walk` needs that commit itself locked. See
# "WHICH COMMIT'S LOCK" at the top of action.yml.
if [ "${#LAYER_ARGS[@]}" -gt 0 ]; then
  case "${GITHUB_EVENT_NAME}" in
  pull_request) CANDS="${PR_BASE_SHA:-}" ;;
  push) CANDS="${GITHUB_SHA} ${EVENT_BEFORE:-}" ;;
  *) CANDS="${GITHUB_SHA}" ;;
  esac
  for c in ${CANDS}; do
    [ -z "${c}" ] && continue
    [ "${c}" = "0000000000000000000000000000000000000000" ] && continue
    probe_rc=0
    "${RESOLVER}" --repo "${SELF}" --sibling "${NAMES[0]}" \
      "${LAYER_ARGS[@]}" --sha "${c}" --no-walk >/dev/null || probe_rc=$?
    # Exit 4 — "a lock exists for this commit, but no manifest layer names the
    # probed sibling" — is an answer ABOUT THE SIBLING, not about the lock. The
    # lock was found, so this commit IS the locked commit, and it is the right
    # commit for every other sibling in the list. Treating it as "the lock
    # cannot be used" made the whole step's success depend on whether the first
    # lock-resolved entry happened to be a member of the workspace project, and
    # reported a membership gap as a corrupt artifact. The per-sibling pass
    # below reports it by name instead.
    if [ "${probe_rc}" -eq 0 ] || [ "${probe_rc}" -eq 4 ]; then
      LOCK_SHA="${c}"
      break
    fi
    # Exit 3 is the resolver's only "this commit is not locked" answer, and the
    # only one worth trying the next candidate for. What is left (5 malformed,
    # 6 self-contradictory) means a lock EXISTS but cannot be trusted. Falling
    # through to the next candidate would bury that behind the generic "no lock"
    # error below and could pin siblings from a DIFFERENT commit, so stop here.
    if [ "${probe_rc}" -ne 3 ]; then
      echo "::error::Workspace lock for ${SELF}@${c} exists but cannot be used (resolve-sibling-rev exit ${probe_rc}); see its diagnostic above."
      exit 1
    fi
  done
  if [ -z "${LOCK_SHA}" ]; then
    LAYERS_DESC="${MANIFESTS_REPO}@${MANIFESTS_REF}"
    if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
      LAYERS_DESC="${LAYERS_DESC} or ${PRIVATE_MANIFESTS_REPO}@${PRIVATE_MANIFESTS_REF}"
    fi
    lock_unavailable "No workspace lock for ${SELF} (candidates: ${CANDS}). Neither a repo-workspaces locks/<project>/${SELF}/<sha>.xml nor a reprobuild locks/<project>/${SELF}/<sha>.toml exists in ${LAYERS_DESC}. The commit must be published through the workspace tooling ('repro workspace lock' / the reprobuild pre-push hook, or legacy 'workspace lock'), and its lock pushed to the manifest repo."
  else
    echo "Resolved workspace-lock commit for ${SELF}: ${LOCK_SHA}"
  fi
fi

# ---------------------------------------------------------------------------
# PASS 1 — resolve every revision. Nothing is cloned yet.
#
# Resolution used to be interleaved with cloning under `set -e`, so the first
# sibling the lock could not answer for aborted the step with some of the others
# already on disk. Two things were wrong with that. A caller bringing N repos
# onto the lock at once learned about them one CI run at a time; and the
# workspace parent was left half-populated, which the next step then builds
# against.
#
# Resolver exit 4 gets its own bucket. It means "a lock exists and no manifest
# layer pins this sibling", which is a statement about the WORKSPACE MEMBERSHIP
# of that repo — its project does not declare it — and not about the health of
# the lock. The others (5 malformed, 6 self-contradictory) are lock defects and
# still stop everything at once.
#
# EVERY entry is asked of the lock, including one that carries an explicit ref.
# The answer does not change what an explicit entry clones; it changes what this
# step can SAY about it, which is the difference between an override you can see
# in the log and one nobody finds out about for a week.
declare -a REVS=() SRCS=() LOCKREVS=()
MISSING=""
OVERRIDES=()
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  ref="${REFS[$i]}"

  lock_rev=""
  if [ -n "${LOCK_SHA}" ]; then
    rrc=0
    lock_rev="$("${RESOLVER}" --repo "${SELF}" --sibling "${name}" \
      "${LAYER_ARGS[@]}" --sha "${LOCK_SHA}" --no-walk 2>"${RUNNER_TEMP}/resolve.err")" || rrc=$?
    if [ "${rrc}" -ne 0 ]; then
      lock_rev=""
      # 5 (malformed) and 6 (contradictory) are lock defects. For a BARE entry
      # they are fatal, as they always have been. For an explicit one the
      # revision does not come from the lock at all, so the defect costs only
      # the override check — a warning, not a new way for this action to fail a
      # job that used to pass.
      if [ "${rrc}" -ne 4 ] && [ "${rrc}" -ne 3 ]; then
        printf '%s\n' "$(<"${RUNNER_TEMP}/resolve.err")" >&2
        if [ -z "${ref}" ]; then
          echo "::error::Workspace lock for ${SELF}@${LOCK_SHA} exists but cannot be used for sibling '${name}' (resolve-sibling-rev exit ${rrc}); see its diagnostic above."
          exit 1
        fi
        echo "::warning::The workspace lock for ${SELF}@${LOCK_SHA} could not be read for sibling '${name}' (resolve-sibling-rev exit ${rrc}). '${name}' carries an explicit ref so it still clones, but this run cannot tell you whether that ref is replacing a revision the lock pins."
      fi
    fi
  fi

  if [ -z "${ref}" ]; then
    if [ -n "${lock_rev}" ]; then
      REVS+=("${lock_rev}")
      SRCS+=("lock")
      LOCKREVS+=("${lock_rev}")
    else
      MISSING="${MISSING} ${name}"
      REVS+=("")
      SRCS+=("missing")
      LOCKREVS+=("")
    fi
    continue
  fi

  REVS+=("${ref}")
  LOCKREVS+=("${lock_rev}")
  if [ -z "${lock_rev}" ]; then
    # The legitimate escape hatch: the lock has nothing to say about this repo,
    # so the caller's ref is the only answer there is. It still pins nothing
    # unless it is a SHA, and that is worth one line in the log — but it is not
    # an override of anything.
    SRCS+=("explicit")
    if ! is_sha40 "${ref}"; then
      echo "::warning::sibling '${name}' is pinned by the explicit entry '${name}=${ref}', not by the workspace lock, and '${ref}' is not a 40-hex commit SHA. This build is therefore not reproducible for '${name}': it resolves to wherever that ref points right now. The lock does not pin '${name}' at all, so the lasting fix is to declare it in ${SELF}'s project manifest."
    fi
  elif [ "${ref}" = "${lock_rev}" ]; then
    # Names exactly what the lock names, so nothing is overridden and nothing is
    # warned about. Reported in the table with its own label all the same,
    # because a hand-written SHA that agrees today starts overriding the moment
    # the lock moves — and there is an entry in this org's fleet in exactly that
    # state right now.
    SRCS+=("explicit-agrees")
  else
    SRCS+=("override")
    [ "${ACKED[$i]}" -eq 1 ] || OVERRIDES+=("${name}|${lock_rev}|${ref}")
  fi
done

if [ -n "${MISSING}" ]; then
  FIX_IN="${MANIFESTS_REPO}"
  if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
    FIX_IN="${FIX_IN} (or ${PRIVATE_MANIFESTS_REPO}, for repos that belong in the private layer)"
  fi
  echo "::error::The workspace lock for ${SELF}@${LOCK_SHA} pins no revision for these sibling(s):${MISSING}. The lock is intact — it answered for the others — so this is not a corrupt or stale lock. A lock can only pin what its project declares, and these repos are not members of the workspace project that lock describes, so it has nothing to say about them."
  echo "::error::THE FIX, in this order. (1) Declare them in ${SELF}'s project manifest in ${FIX_IN}; the next lock then pins them, and every lock after that, with nothing left to maintain. Siblings are keyed by repo NAME, which can differ from the workspace path, so check the spelling before concluding a repo is missing. (2) Only where (1) is genuinely impossible, name a revision explicitly with a '<name>=<40-hex sha>' entry in 'siblings' — a commit SHA, never a branch. Do NOT reach for '<name>=<branch>' to clear this error: cloning a branch tip is precisely the unpinned, unreproducible fallback this action refuses to have. And do NOT add a ref to entries this error does not name — those are pinned correctly right now, and adding one would un-pin them."
  exit 1
fi

# ---------------------------------------------------------------------------
# The resolution table. One line per sibling, on every run, whether or not
# anything is wrong — an accidental override has to be visible in a log that
# SUCCEEDED, which is the only kind of log this case ever produced.
if [ -n "${LOCK_SHA}" ]; then
  echo "Sibling resolution for ${SELF} (workspace lock ${SELF}@${LOCK_SHA}):"
else
  echo "Sibling resolution for ${SELF} (no workspace lock was consulted):"
fi
for i in "${!NAMES[@]}"; do
  case "${SRCS[$i]}" in
  lock) note="" ;;
  explicit) note="  <- the lock does not pin this repo" ;;
  explicit-agrees) note="  <- the same revision the lock pins" ;;
  override)
    if [ "${ACKED[$i]}" -eq 1 ]; then
      note="  <- acknowledged with '!='; the lock pins ${LOCKREVS[$i]}"
    else
      note="  <- UNACKNOWLEDGED; the lock pins ${LOCKREVS[$i]}"
    fi
    ;;
  *) note="" ;;
  esac
  echo "  ${OWNERS[$i]}/${NAMES[$i]} -> ${REVS[$i]} (${SRCS[$i]})${note}"
done

# ---------------------------------------------------------------------------
# An explicit ref that replaces a revision the lock PINS.
#
# This is the dangerous half of `name=ref`, and until now it happened in
# complete silence. A bare `name` means "whatever the lock pins"; adding `=ref`
# to it takes a repo that was pinned, reproducibly, and turns it into whatever
# that ref points at when the job runs. Nothing about that is visible in a green
# build: CI keeps passing, and the drift surfaces days later somewhere that
# looks unrelated. This action already fails loudly on a MISSING lock for
# exactly this reason; an override of a lock that EXISTS is the same loss of
# reproducibility, chosen rather than suffered.
#
# WHY THE ACKNOWLEDGEMENT IS PER-ENTRY. `name!=ref` says "yes, I mean this one".
# The alternative — one action-level switch that permits overrides for the whole
# list — reproduces the exact mistake this check was written after: a caller
# under pressure sets the switch once, and from then on every entry in the list,
# including the ones the lock was pinning perfectly well, is silently exempt.
# That is the near-miss, restored as a feature. An acknowledgement that has to
# be written on the entry it applies to cannot spread on its own, and shows up
# in a diff next to the thing it excuses.
#
# WHY THE DEFAULT IS `warn` AND NOT `error`. Every consumer of this action pins
# `@main`, so a new hard failure lands on all of them at once with no way to
# prepare. A sweep of the org found real callers overriding lock pins today —
# one `.github/sibling-repos` in which 15 of 21 explicit entries name a repo the
# lock pins, including a 40-hex pin that has drifted from the lock's. Failing by
# default would take those workflows out the moment this merged, which is the
# fleet-wide outage this change exists to prevent, arriving as the change
# itself. So the default is loud and non-breaking; a repo that has acknowledged
# its overrides sets `on-lock-override: error` and can never regress; and the
# default flips once the fleet is clean, at which point every deliberate
# override is already spelled `!=` and nothing breaks at the flip.
if [ "${#OVERRIDES[@]}" -gt 0 ]; then
  OV_HEAD="clone-siblings: ${#OVERRIDES[@]} sibling entry/entries override a revision the workspace lock already pins for ${SELF}@${LOCK_SHA}."
  if [ "${ON_LOCK_OVERRIDE}" = "error" ]; then
    echo "::error::${OV_HEAD}"
  else
    echo "::warning::${OV_HEAD} This build is NOT reproducible from the lock."
  fi
  for r in "${OVERRIDES[@]}"; do
    rn="${r%%|*}"
    rest="${r#*|}"
    echo "    ${rn}: the lock pins ${rest%%|*} -> this entry requests '${rest#*|}'"
  done
  echo "  IF THE PIN IS WHAT YOU WANT (it usually is): delete the '=<ref>' and leave the bare name. The lock then keeps the repo pinned for every future commit, with nothing to maintain."
  echo "  IF THE OVERRIDE IS DELIBERATE: spell it '<name>!=<ref>'. It is per-entry on purpose, so acknowledging one override cannot quietly exempt the rest of the list. The entries above become:"
  for r in "${OVERRIDES[@]}"; do
    rn="${r%%|*}"
    rest="${r#*|}"
    echo "      ${rn}!=${rest#*|}"
  done
  if [ "${ON_LOCK_OVERRIDE}" != "error" ]; then
    echo "  This is a warning and not a failure only because this action is consumed at '@main' fleet-wide. Once this repo's overrides are all acknowledged, set 'on-lock-override: error' so it cannot regress."
  fi

  # The Actions job summary, so an override is visible on the run's summary page
  # and not only to whoever opens the raw log of one job out of fifteen. A
  # warning nobody is shown is the same as no warning, which is what the silent
  # version of this was.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### clone-siblings: workspace-lock pin overridden"
      echo ""
      echo "\`${SELF}\` cloned ${#OVERRIDES[@]} sibling(s) at a revision **other than** the one the workspace lock pins, so this build is not reproducible from the lock."
      echo ""
      echo "| sibling | lock pins | entry requests |"
      echo "| --- | --- | --- |"
      for r in "${OVERRIDES[@]}"; do
        rn="${r%%|*}"
        rest="${r#*|}"
        echo "| \`${rn}\` | \`${rest%%|*}\` | \`${rest#*|}\` |"
      done
      echo ""
      echo "Delete the \`=<ref>\` to keep the pin, or spell it \`<name>!=<ref>\` to acknowledge the override."
    } >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
  fi

  if [ "${ON_LOCK_OVERRIDE}" = "error" ]; then
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# PASS 2 — clone, now that every revision is known and legal.
SIBLING_PATHS=""
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  owner="${OWNERS[$i]}"
  rev="${REVS[$i]}"
  WORKSPACE_NORM="${GITHUB_WORKSPACE//\\//}"
  dest="${WORKSPACE_NORM}/../${name}"
  # Credential-free URL; the scoped extraHeader in this step's environment
  # authenticates it, and `git submodule update --recursive` inherits that
  # environment at every depth — which is what keeps the PRIVATE submodule path
  # working (codetracer's libs/tree-sitter-nim inside a public repo,
  # codetracer-native-backend recursing into a private codetracer-rr) with
  # nothing written to any `.git/config`.
  #
  # Failures are no longer discarded to /dev/null: an owner-scoped credential
  # makes auth-denied a reachable configuration error, and the previous code
  # produced no output at all for it.
  bash "${GIT_AUTH_DIR}/authenticated-clone.sh" \
    --repo "${owner}/${name}" --dest "${dest}" --rev "${rev}" \
    --shallow --submodules-optional
  SIBLING_PATHS="${SIBLING_PATHS} ${name}=$(cd "${dest}" && pwd)"
done
# Expose the clone locations for later steps (e.g. flake overrides).
echo "CT_SIBLING_PATHS=${SIBLING_PATHS# }" >>"${GITHUB_ENV}"
echo "Cloned ${#NAMES[@]} sibling(s) adjacent to the host checkout."
