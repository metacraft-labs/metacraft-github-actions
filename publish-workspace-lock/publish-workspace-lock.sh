#!/usr/bin/env bash
#
# publish-workspace-lock.sh -- the body of publish-workspace-lock/action.yml's
# one composite step.
#
# WHY IT IS A FILE AND NOT A `run: |` BLOCK.
#
# GitHub evaluates a composite `run:` body as a TEMPLATE EXPRESSION and rejects
# one longer than 21000 characters -- at parse time, which fails every
# consumer's job before its first step rather than failing this repo's CI.
# `.github/assert-composite-run-size.sh` guards the budget and names this
# remedy, which `refresh-workspace-lock` already follows. Every value the step
# needs still arrives through the step's `env:` block, exactly as before; this
# file contains no GitHub Actions template substitution and must not grow one,
# because nothing here would expand it. The suite enforces that by refusing the
# opening delimiter anywhere in this file -- including in a comment, which is
# why this paragraph spells it out in words.
#
# `publish-workspace-lock-step-test.sh` executes THIS FILE, so the suite and
# the runner run the same bytes.

set -euo pipefail
MANIFESTS_REF="${INPUT_MANIFESTS_REF:-latest}"
PRIVATE_MANIFESTS_REF="${INPUT_PRIVATE_MANIFESTS_REF:-${MANIFESTS_REF}}"
SELF_SLUG="${INPUT_REPO:-${DEFAULT_REPO}}"

# -----------------------------------------------------------------
# Shape validation, before anything is cloned or fetched.
#
# Every value below is substituted into a git command line. `git fetch
# <remote> <rev>` parses options after the remote, so a `--upload-pack=`
# in a ref runs a command on the runner; and a SHA that is not a SHA
# would be published as a lock FILENAME, which is the one thing in this
# system that must be a commit and nothing else. The resolver refuses
# such values on the read side (`check_rev_shape`); refusing them here
# is the same rule on the write side.
# -----------------------------------------------------------------
die() { echo "::error::$*"; exit 1; }

check_sha() { # <label> <value>
  case "$2" in
    *[!0-9a-f]*|"") die "${1} must be a 40-character lowercase hex commit SHA; got '${2}'." ;;
  esac
  [ "${#2}" -eq 40 ] || die "${1} must be a 40-character lowercase hex commit SHA; got '${2}'."
}
check_sha "source-sha" "${SOURCE_SHA}"
check_sha "target-sha" "${TARGET_SHA}"
if [ "${SOURCE_SHA}" = "${TARGET_SHA}" ]; then
  die "source-sha and target-sha name the same commit (${TARGET_SHA}). A mainline commit that IS the locked commit needs no re-anchoring, and publishing one onto itself would be a no-op dressed as a fix."
fi

case "${BASE_REF}" in
  ""|-*|.*|/*) die "base-ref must be a branch name, not starting with '-', '.' or '/'; got '${BASE_REF}'." ;;
  *[!0-9A-Za-z._/-]*) die "base-ref must contain only [0-9A-Za-z._/-]; got '${BASE_REF}'." ;;
esac

check_slug() { # <label> <owner/name>
  case "$2" in
    */*/*|*/|/*|"") die "${1} must be 'owner/name'; got '${2}'." ;;
    */*) : ;;
    *) die "${1} must be 'owner/name'; got '${2}'." ;;
  esac
  case "$2" in
    *[!0-9A-Za-z._/-]*) die "${1} must contain only [0-9A-Za-z._/-]; got '${2}'." ;;
  esac
}
check_slug "repo" "${SELF_SLUG}"
check_slug "manifests-repo" "${MANIFESTS_REPO}"
[ -z "${PRIVATE_MANIFESTS_REPO}" ] || check_slug "private-manifests-repo" "${PRIVATE_MANIFESTS_REPO}"

SELF_OWNER="${SELF_SLUG%%/*}"
SELF_NAME="${SELF_SLUG#*/}"

[ -n "${GH_TOKEN}" ] || die "gh-token is empty. This action must PUSH the re-anchored lock record to ${MANIFESTS_REPO}; there is no unauthenticated path to that, and failing here is better than failing halfway through a publish."
[ -x "${ANCHOR}" ] || [ -f "${ANCHOR}" ] || die "anchor-workspace-lock.sh not found at ${ANCHOR}."

# -----------------------------------------------------------------
# The credential. Same mechanism as clone-siblings: an owner-scoped
# `http.<url>.extraHeader` in PROCESS-scoped git configuration, so the
# token never reaches an argv, a URL, or any `.git/config` that
# outlives this step. The scope covers the repo being locked (read, for
# the ancestry proof) and every manifest layer (write).
# -----------------------------------------------------------------
# shellcheck source=../git-auth/scoped-git-auth.sh
. "${GIT_AUTH_DIR}/scoped-git-auth.sh"
# Deduplicated: the repo being locked and the manifest layers usually
# share an owner, and a scope reported twice reads as a bug in the
# scoping.
OWNERS=()
add_owner() {
  local o
  for o in ${OWNERS[@]+"${OWNERS[@]}"}; do [ "${o}" = "$1" ] && return 0; done
  OWNERS+=("$1")
}
add_owner "${SELF_OWNER}"
add_owner "${MANIFESTS_REPO%%/*}"
[ -z "${PRIVATE_MANIFESTS_REPO}" ] || add_owner "${PRIVATE_MANIFESTS_REPO%%/*}"
export TOKEN_OWNERS="${OWNERS[*]}"
export SCOPED_GIT_AUTH_REWRITES=1
export SCOPED_GIT_AUTH_MASK=1
scoped_git_auth_build
scoped_git_auth_export
scoped_git_auth_report
if [ -n "${JOB_TOKEN_OWNERS//[[:space:]]/}" ]; then
  TOKEN_OWNERS="${JOB_TOKEN_OWNERS}" \
    scoped_git_auth_require_covered "publish-workspace-lock" "${OWNERS[@]}" || exit 1
fi

WORK="${RUNNER_TEMP}/publish-workspace-lock"
rm -rf "${WORK}"
mkdir -p "${WORK}"

# -----------------------------------------------------------------
# PROOF THAT THE TARGET LANDED.
#
# `merge_commit_sha` is the merge commit only once the pull request is
# actually merged; on an open PR the same field names a THROWAWAY test
# merge. A record filed under such a SHA is unreachable garbage in an
# append-only, immutable store, and mainline stays unlocked — the exact
# symptom this action exists to remove, now with a record that looks
# like a fix. So the claim is not taken from the payload: the base
# branch is fetched from the repo itself (commits and trees only, no
# blobs) and the ancestry is proven locally.
# -----------------------------------------------------------------
SELF_GIT="${WORK}/self.git"
SELF_URL="https://github.com/${SELF_SLUG}.git"
echo "Fetching ${SELF_SLUG}@${BASE_REF} to prove ${TARGET_SHA} landed on it..."
# Commits and trees only: the proof is about ancestry, and no file
# content is read. A server that refuses a partial clone is not an error
# condition, it is an older server — retry whole rather than skip the
# proof, which is the one thing that must not become optional.
if ! git clone --quiet --bare --no-tags --filter=blob:none \
       --single-branch --branch "${BASE_REF}" "${SELF_URL}" "${SELF_GIT}"; then
  rm -rf "${SELF_GIT}"
  git clone --quiet --bare --no-tags \
    --single-branch --branch "${BASE_REF}" "${SELF_URL}" "${SELF_GIT}" \
    || die "Cannot clone ${BASE_REF} from ${SELF_SLUG}. The ancestry of ${TARGET_SHA} cannot be proven, and nothing is published without that proof."
fi
if ! git -C "${SELF_GIT}" merge-base --is-ancestor "${TARGET_SHA}" "refs/heads/${BASE_REF}" 2>/dev/null; then
  die "${TARGET_SHA} is not an ancestor of ${SELF_SLUG}@${BASE_REF}. It is not a commit that landed on the mainline, so a lock record filed under it would pin nothing and could never be reached. (An open pull request's merge_commit_sha names a throwaway test merge; this is what that looks like.)"
fi
echo "Proven: ${TARGET_SHA} is an ancestor of ${SELF_SLUG}@${BASE_REF}."

# -----------------------------------------------------------------
# THE CARRY MUST NOT OUTRUN ITS EVIDENCE.
#
# This action re-files a record; it does not observe one. That is
# sound exactly as far as the record's claim still holds at the commit
# it is being filed under, and the `push` wiring stretches that claim
# by one commit on every push: `github.event.before` supplies the
# sibling set and `github.sha` receives it, so the composition
# recorded for a mainline commit was observed at some ancestor and
# carried forward, link by link, from whatever seeded the chain.
#
# For a commit that changed nothing about the workspace that is fine,
# and it is the reason the chain exists: without it `clone-siblings`
# answers "no workspace lock found for <repo>" and every cross-repo
# job dies before it builds anything.
#
# For a commit that BUMPED A SIBLING it is false, and the workflow
# comment that wires this action says so in as many words: "if a
# pushed commit BUMPED a sibling, the carried set predates that bump."
# A record published in that state does not merely lag — it
# CONTRADICTS the commit it names, and because publication is
# additions-only and records are immutable, the coordinate is then
# burned: the real composition for that commit can never be recorded.
# That is strictly worse than the missing record, which at least fails
# loudly and names a remedy.
#
# The bump is detectable without observing anything: the repo's own
# committed `repro.lock` IS its declaration of the composition, so if
# it differs between the source and the target the carried set is
# known-wrong for the target. A tree-to-tree comparison answers that
# from the blobless clone above (`--name-only --no-renames` reads tree
# entries, never file content), and it is evaluated only when the
# source is genuinely an ancestor of the target — a `workflow_dispatch`
# backfill may legitimately name two SHAs with no ancestry between
# them, and an operator stating both is an informed act, not a carry.
# -----------------------------------------------------------------
CARRY_WITNESS="repro.lock"
if git -C "${SELF_GIT}" cat-file -e "${SOURCE_SHA}^{commit}" 2>/dev/null &&
   git -C "${SELF_GIT}" merge-base --is-ancestor \
     "${SOURCE_SHA}" "${TARGET_SHA}" 2>/dev/null; then
  CARRY_MOVED="$(git -C "${SELF_GIT}" diff-tree -r --name-only \
    --no-commit-id --no-renames "${SOURCE_SHA}" "${TARGET_SHA}" \
    -- "${CARRY_WITNESS}" 2>/dev/null || true)"
  if [ -n "${CARRY_MOVED}" ]; then
    die "${SELF_NAME}'s own ${CARRY_WITNESS} differs between ${SOURCE_SHA} and ${TARGET_SHA}, so the composition CHANGED across the range this carry spans. The record published for ${SOURCE_SHA} states the sibling set as it was BEFORE that change; filing it under ${TARGET_SHA} would publish a set that contradicts the commit it names, and a published record is immutable, so ${TARGET_SHA} could never afterwards record its real state. Nothing is published. The sibling set for this commit has to be OBSERVED, not carried: regenerate it from a real workspace (refresh-workspace-lock opens that as a pull request, so the composition is built before it is published), then re-run this workflow's workflow_dispatch backfill with a source-sha whose record actually describes ${TARGET_SHA}."
  fi
  echo "Carry checked: ${CARRY_WITNESS} is unchanged between ${SOURCE_SHA} and ${TARGET_SHA}; the source record's sibling set still describes the target."
else
  echo "Carry span not evaluated: ${SOURCE_SHA} is not an ancestor of ${TARGET_SHA} in ${SELF_SLUG}@${BASE_REF} (or is not present on it). This is the workflow_dispatch backfill shape, where both SHAs are stated by an operator rather than derived from a branch's previous tip."
fi

# -----------------------------------------------------------------
# Publish into one manifest layer.
#
# Layers are independent stores. A repo whose lock lives in the private
# layer gets its re-anchored record THERE; it is never demoted into the
# public layer, which would publish a private workspace's sibling set
# to everyone and would also be read at a different precedence.
# -----------------------------------------------------------------
PUBLISHED_TOTAL=0
FOUND_ANY=0

publish_layer() { # <label> <owner/name> <branch> <dir>
  local label="$1" slug="$2" ref="$3" dir="$4"
  local url="https://github.com/${slug}.git"
  echo "Cloning ${label} manifest layer ${slug}@${ref}..."
  # Full history of the one branch: the record is committed and pushed
  # from this checkout, and the race recovery below re-applies onto a
  # moved tip. A shallow clone cannot be pushed from reliably.
  git clone --quiet --branch "${ref}" --single-branch "${url}" "${dir}" \
    || die "Failed to clone the ${label} manifest layer ${slug} on branch ${ref}."

  local attempt=0 budget=8
  while :; do
    local -a srcs=() dests=()
    local f dest ext stem
    # `locks/<project>/<repo>/<sha>.<ext>` and the historical flat
    # `locks/<project>/<repo>-<sha>.<ext>`, both extensions — the same
    # four shapes resolve-sibling-rev.sh searches, so a record this
    # action cannot see is a record the resolver cannot read either.
    for f in \
        "${dir}"/locks/*/"${SELF_NAME}"/"${SOURCE_SHA}".toml \
        "${dir}"/locks/*/"${SELF_NAME}"/"${SOURCE_SHA}".xml \
        "${dir}"/locks/*/"${SELF_NAME}-${SOURCE_SHA}".toml \
        "${dir}"/locks/*/"${SELF_NAME}-${SOURCE_SHA}".xml; do
      [ -f "${f}" ] || continue
      ext="${f##*.}"
      stem="${f%.*}"
      case "${stem}" in
        */"${SELF_NAME}/${SOURCE_SHA}") dest="${stem%/*}/${TARGET_SHA}.${ext}" ;;
        *"/${SELF_NAME}-${SOURCE_SHA}") dest="${stem%-*}-${TARGET_SHA}.${ext}" ;;
        *) die "Cannot derive a destination path for ${f}; refusing to guess." ;;
      esac
      srcs+=("${f}")
      dests+=("${dest}")
    done

    if [ "${#srcs[@]}" -eq 0 ]; then
      echo "No lock record for ${SELF_NAME}@${SOURCE_SHA} in the ${label} layer."
      return 0
    fi
    FOUND_ANY=1

    # Re-anchor every record found, into a staging file first. Nothing
    # touches the checkout until every transform has succeeded, so a
    # record this tool refuses cannot leave a half-published commit.
    local i=0 body rc anchored_any=0
    local -a pending_src=() pending_dest=()
    while [ "${i}" -lt "${#srcs[@]}" ]; do
      f="${srcs[$i]}"
      dest="${dests[$i]}"
      i=$((i + 1))
      body="${WORK}/anchored.$$.${i}"
      rc=0
      bash "${ANCHOR}" --repo "${SELF_NAME}" \
        --source-sha "${SOURCE_SHA}" --target-sha "${TARGET_SHA}" \
        --in "${f}" --out "${body}" || rc=$?
      if [ "${rc}" -ne 0 ]; then
        die "Cannot re-anchor ${f#${dir}/} onto ${TARGET_SHA} (anchor-workspace-lock exit ${rc}); see its diagnostic above."
      fi
      if [ -f "${dest}" ]; then
        # Published records are IMMUTABLE. Identical bytes mean another
        # run (or another publisher) already did this and we are done;
        # different bytes mean two different answers for one commit,
        # which is the one thing that must never be resolved by
        # overwriting.
        #
        # COMPARED WITH `git hash-object`, NOT `cmp`, AND THE REASON IS
        # A REAL FAILURE. `cmp -s` exits non-zero for "the files
        # differ" AND for "cmp is not on PATH", and this branch cannot
        # tell those apart: it read the second as the first and
        # announced a disagreement it had never measured. That is not
        # hypothetical — `metacraft-labs/codetracer-launcher` run
        # 34844401895 died with
        #
        #   line 198: cmp: command not found
        #   A DIFFERENT lock record is already published at ...
        #
        # against a destination whose bytes were IDENTICAL (verified
        # afterwards: both sha256
        # 745e7fb54d06d88de96a343eb98c347892ac3bcfc72eb98f778726f455e261ac).
        # `cmp` ships in diffutils, which a hosted `ubuntu-latest`
        # image carries and a self-hosted nixos runner's PATH need not
        # — and every PRIVATE repo wiring this action has to use a
        # self-hosted runner, because a hosted job there does not
        # start. So the tool this check depended on is absent exactly
        # where the check matters most, and it fails in the worse
        # direction: a retried job reports an immutability violation
        # instead of a no-op.
        #
        # `git hash-object` is exact (a hash over the file's bytes),
        # needs no repository, and git is already a hard dependency of
        # every step in this action. An unavailable git is diagnosed as
        # itself rather than silently read as "the records differ".
        local body_id dest_id
        body_id="$(git hash-object -- "${body}" 2>/dev/null || true)"
        dest_id="$(git hash-object -- "${dest}" 2>/dev/null || true)"
        if [ -z "${body_id}" ] || [ -z "${dest_id}" ]; then
          die "Cannot compare the re-anchored record with the one already published at ${dest#${dir}/}: 'git hash-object' produced no digest. Nothing is published and nothing is rewritten; this is a broken environment, NOT a disagreement about ${SELF_NAME}@${TARGET_SHA}."
        fi
        if [ "${body_id}" = "${dest_id}" ]; then
          echo "Already published: ${dest#${dir}/} (identical bytes)."
          continue
        fi
        die "A DIFFERENT lock record is already published at ${dest#${dir}/}. Published records are immutable and this one is not rewritten. Two sources disagree about the sibling set of ${SELF_NAME}@${TARGET_SHA}; resolve that before re-running."
      fi
      pending_src+=("${body}")
      pending_dest+=("${dest}")
      anchored_any=1
    done

    if [ "${anchored_any}" -eq 0 ]; then
      echo "${label} layer: nothing to publish; every destination record already exists."
      return 0
    fi

    i=0
    local -a rels=()
    while [ "${i}" -lt "${#pending_dest[@]}" ]; do
      dest="${pending_dest[$i]}"
      mkdir -p "${dest%/*}"
      cp "${pending_src[$i]}" "${dest}"
      rels+=("${dest#${dir}/}")
      i=$((i + 1))
    done

    git -C "${dir}" add -f -- "${rels[@]}"

    # ADDITIONS ONLY. Anything staged that is not a new file under
    # `locks/` means this step is about to rewrite published history,
    # and no diagnostic downstream would be as clear as stopping here.
    local st path
    while IFS=$'\t' read -r st path; do
      [ -n "${st}" ] || continue
      case "${st}${path}" in
        "Alocks/"*) : ;;
        *) die "Refusing to publish: the staged change is not an addition under locks/ (${st} ${path})." ;;
      esac
    done < <(git -C "${dir}" diff --cached --name-status --no-renames)

    local msg="Publish ${#rels[@]} workspace lock entry"
    [ "${#rels[@]}" -eq 1 ] || msg="Publish ${#rels[@]} workspace lock entries"
    msg="${msg} for ${SELF_NAME}@${TARGET_SHA}"
    local body_msg="Re-anchored from the lock published for ${SELF_NAME}@${SOURCE_SHA}."
    [ -z "${PROVENANCE}" ] || body_msg="${body_msg}"$'\n'"Landed by ${PROVENANCE}."
    git -C "${dir}" \
      -c "user.name=${COMMITTER_NAME}" -c "user.email=${COMMITTER_EMAIL}" \
      commit --quiet --no-gpg-sign -m "${msg}" -m "${body_msg}" -- "${rels[@]}"

    local push_out push_rc=0
    push_out="$(git -C "${dir}" push origin "HEAD:refs/heads/${ref}" 2>&1)" || push_rc=$?
    if [ "${push_rc}" -eq 0 ]; then
      # Positive verification. A push that "succeeded" without the blob
      # arriving is indistinguishable from a fix that works, until the
      # next CI run says otherwise.
      git -C "${dir}" fetch --quiet --no-tags origin "refs/heads/${ref}"
      local rel
      for rel in "${rels[@]}"; do
        git -C "${dir}" cat-file -e "FETCH_HEAD:${rel}" 2>/dev/null \
          || die "Pushed to ${slug}@${ref}, but ${rel} is not present at the remote tip afterwards."
        echo "Published ${rel} to ${slug}@${ref}."
      done
      PUBLISHED_TOTAL=$((PUBLISHED_TOTAL + ${#rels[@]}))
      return 0
    fi

    # A LOST RACE, recognised by shape. Any other failure (auth, DNS, a
    # declining pre-receive hook) is reported as itself rather than
    # retried into a timeout.
    case "${push_out}" in
      *"[rejected]"*|*"[remote rejected]"*) : ;;
      *) die "Failed to push to ${slug}@${ref}: ${push_out}" ;;
    esac
    case "${push_out}" in
      *"non-fast-forward"*|*"fetch first"*|*"behind"*|*"stale info"*|*"failed to update ref"*|*"cannot lock ref"*) : ;;
      *) die "Push to ${slug}@${ref} was rejected for a reason that is not a lost race: ${push_out}" ;;
    esac

    attempt=$((attempt + 1))
    if [ "${attempt}" -gt "${budget}" ]; then
      die "Lost the publish race on ${slug}@${ref} ${budget} times in a row. Last rejection: ${push_out}"
    fi
    echo "Another publisher moved ${slug}@${ref}; re-applying (attempt ${attempt}/${budget})."
    # Records are commit-addressed, so concurrent publishers write
    # disjoint paths and the work simply replays onto the new tip. The
    # loop restarts from the search deliberately: the other publisher
    # may have added THIS record, in which case the immutability check
    # above turns the race into an idempotent success.
    git -C "${dir}" fetch --quiet --no-tags origin "refs/heads/${ref}"
    git -C "${dir}" reset --quiet --hard FETCH_HEAD
    git -C "${dir}" clean -qfd
  done
}

publish_layer public "${MANIFESTS_REPO}" "${MANIFESTS_REF}" "${WORK}/public"
if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
  publish_layer private "${PRIVATE_MANIFESTS_REPO}" "${PRIVATE_MANIFESTS_REF}" "${WORK}/private"
fi

if [ "${FOUND_ANY}" -eq 0 ]; then
  LAYERS_DESC="${MANIFESTS_REPO}@${MANIFESTS_REF}"
  if [ -n "${PRIVATE_MANIFESTS_REPO}" ]; then
    LAYERS_DESC="${LAYERS_DESC} or ${PRIVATE_MANIFESTS_REPO}@${PRIVATE_MANIFESTS_REF}"
  fi
  die "No workspace lock is published for ${SELF_NAME}@${SOURCE_SHA} in ${LAYERS_DESC}, so there is nothing to re-anchor onto ${TARGET_SHA} and this action will not invent one. ${TARGET_SHA} therefore has no reproducible sibling snapshot, and cross-repo CI cannot resolve against it. The source commit is a pull request HEAD, and a pull request HEAD is locked by the PRE-PUSH GATE when its branch is pushed. It is missing when that gate did not run: the author's checkout has no managed hooks ('repro hooks ensure --vcs <repo>'), the push used --no-verify, or the branch came from a fork. Remedy: from a workspace holding ${SOURCE_SHA}, run 'repro ws lock' and push it once from a workspace, then re-run this workflow (workflow_dispatch, with source-sha=${SOURCE_SHA} and target-sha=${TARGET_SHA})."
fi

echo "publish-workspace-lock: ${PUBLISHED_TOTAL} record(s) published for ${SELF_NAME}@${TARGET_SHA}."
