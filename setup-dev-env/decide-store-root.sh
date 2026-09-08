#!/usr/bin/env bash
#
# decide-store-root.sh — point reprobuild at the runner's SHARED
# content-addressed store when there is one, and say which store was chosen.
#
# WHAT THIS FIXES
# ---------------
# Self-hosted Linux CI runners are given a shared, persistent reprobuild CAS,
# bind-mounted into each per-job container at a well-known path (`/srv/repro-store`
# by default). The point of it is that a build artefact realised by one job is
# still there for the next one — the runners themselves are ephemeral, the store
# is not.
#
# Reprobuild will use it, but only if told to. `REPRO_STORE_ROOT` is the
# canonical selector; with it unset, reprobuild falls back to the per-user
# default (`$XDG_CACHE_HOME/repro/store`, else `$HOME/.cache/repro/store`),
# which inside an ephemeral per-job container is destroyed with the container.
#
# Nothing in CI was setting that variable. So the mount was provisioned,
# mounted, and never written to: every job built into a store that was thrown
# away minutes later, and the shared store stayed empty from the day it was
# created. That is a configuration gap, not a defect in reprobuild — the
# mechanism works, it simply had no caller.
#
# WHY HERE
# --------
# `setup-dev-env` is the uniform entry point: every repo in the fleet enters CI
# through it, under one of three env flavors. Putting the decision here means
# one place decides for all of them.
#
# It runs on EVERY flavor, not just `reprobuild`, because the discriminator is
# the MOUNT, not the flavor. A `nix` job whose devShell happens to ship `repro`
# uses the same store, and `$REPRO_STORE_ROOT` is also the compat root for the
# action cache. A flavor gate would have excluded those for no benefit, and the
# mount test already excludes every runner that has no shared store.
#
# It runs EARLY — before siblings are provisioned and before the `repro` CLI is
# installed — because `$GITHUB_ENV` is visible to SUBSEQUENT steps only. Steps
# later in this same composite already invoke `repro` (`repro develop --all` on
# the `repro-lock` path), so a decision made at the end would arrive after its
# first consumer.
#
# WHY $GITHUB_ENV AND NOT A PER-STEP export
# -----------------------------------------
# The steps that actually populate the store are the CALLER'S — `dev-exec repro
# build`, `dev-exec just test` — and this action does not wrap them. A per-step
# `env:` would cover only the steps written here, which are the ones that matter
# least. Baking the value into the `dev-exec` wrapper instead would cover a
# little more and still miss any direct `repro` invocation, and would put the
# same value in three wrappers. `$GITHUB_ENV` is one write that every later step
# in the job inherits, and it is how this action already exports the reprobuild
# binary-cache settings.
#
# THE THREE CASES, AND WHY TWO OF THEM ARE SILENT SUCCESSES
# ---------------------------------------------------------
#   present + writable  -> export. The shared store is used.
#   absent              -> do not export. GitHub-hosted runners, macOS and
#                          Windows have no such mount; pointing a store root at
#                          a path that does not exist would be WORSE than the
#                          status quo, because reprobuild would then try to
#                          create it — succeeding somewhere useless, or failing
#                          a job that works fine today.
#   present, unwritable -> do not export. A store root the job cannot write
#                          fails late, inside a build, with a diagnostic about
#                          a store rather than about a mount.
#
# Neither of the last two FAILS the job, and that is deliberate: not exporting
# is not a degraded state, it is the per-user default that every runner without
# a shared store uses successfully. Turning a missing optimisation into a red
# build would take out the whole fleet the first time a mount was renamed. What
# is not optional is SAYING which store was chosen — an unnoticed fallback to
# the container-local store is precisely the failure this script exists to end,
# and it stayed unnoticed for as long as it did because nothing ever printed a
# store root.
#
# WRITABILITY IS PROBED, NOT ASSUMED. `-w` answers the DAC question and misses a
# read-only remount, a full or quota-exhausted filesystem, and an ACL. The store
# is shared between mutually untrusted per-job containers and is therefore
# world-writable and sticky, which makes `-w` true for shapes that still cannot
# be written. So a file is actually created and removed. The probe is a dotfile
# at the store root, which is not the shape of a store entry
# (`<algo>-<digest>-<name>/`), and it is unlinked immediately.
#
# A CALLER'S OWN VALUE WINS. If `REPRO_STORE_ROOT` is already set, it is left
# alone and reported. A job that has deliberately pointed at its own store must
# not have it replaced by a mount that merely happens to exist.
#
# PORTABILITY. Pure bash builtins plus `rm`. No awk/sed/grep: this runs on
# GitHub's macOS images (bash 3.2), on Windows via Git Bash, and on minimal
# self-hosted runners. Same rule as decide-sibling-strategy.sh.
#
# INPUTS arrive as environment variables set by the action's `env:` block.
set -euo pipefail

CANDIDATE="${SHARED_STORE_PATH-/srv/repro-store}"

# DECISION is one of:
#   caller       — REPRO_STORE_ROOT was already set; untouched
#   disabled     — shared-store-path was set empty; the probe is switched off
#   absent       — no directory at the candidate path (the common case off-fleet)
#   not-writable — the directory is there but this job cannot write to it
#   probe-failed — it looked writable and a real write did not work
#   shared       — exported
DECISION=""
REASON=""
STORE_ROOT=""

if [ -n "${REPRO_STORE_ROOT:-}" ]; then
  DECISION="caller"
  STORE_ROOT="${REPRO_STORE_ROOT}"
  REASON="REPRO_STORE_ROOT was already set to ${REPRO_STORE_ROOT} before this action ran; leaving it alone"
elif [ -z "${CANDIDATE}" ]; then
  DECISION="disabled"
  REASON="shared-store-path is empty, so no shared store is looked for"
elif [ ! -d "${CANDIDATE}" ]; then
  DECISION="absent"
  REASON="no shared store is mounted at ${CANDIDATE}; reprobuild will use its per-user default"
elif [ ! -w "${CANDIDATE}" ]; then
  DECISION="not-writable"
  REASON="${CANDIDATE} exists but is not writable by this job; reprobuild will use its per-user default"
else
  # Real write. See the header: -w is a DAC answer, and this mount is
  # world-writable by construction, so -w alone proves very little.
  _probe="${CANDIDATE}/.repro-store-writable-probe.$$.${RANDOM:-0}"
  if (: >"${_probe}") 2>/dev/null; then
    rm -f "${_probe}" 2>/dev/null || true
    if [ -e "${CANDIDATE}/index.db" ] && [ ! -w "${CANDIDATE}/index.db" ]; then
      # The root is world-writable by construction, so writing a file there
      # proves less than it looks. Every store operation also opens the index
      # read-write, and the index is created by whichever job reached the mount
      # first, with that job's ownership. If those jobs do not share a uid — the
      # runners currently do, but nothing pins that — the root probe passes and
      # the build then fails inside reprobuild, talking about a store rather
      # than about a mount. Checking the one file that every operation must open
      # turns that into this line.
      DECISION="not-writable"
      REASON="${CANDIDATE} is writable but its index.db is not writable by this job; reprobuild will use its per-user default"
    else
      DECISION="shared"
      STORE_ROOT="${CANDIDATE}"
      REASON="a writable shared store is mounted at ${CANDIDATE}; build outputs realised by this job persist for later jobs"
    fi
  else
    DECISION="probe-failed"
    REASON="${CANDIDATE} looks writable but a test write failed (read-only remount, full filesystem, or an ACL); reprobuild will use its per-user default"
  fi
fi

if [ "${DECISION}" = "shared" ]; then
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'REPRO_STORE_ROOT=%s\n' "${CANDIDATE}" >>"${GITHUB_ENV}"
  fi
fi

# ---------------------------------------------------------------------------
# Report. Every path, every run, one line — see the header for why silence here
# is the bug rather than the tidy outcome.
# ---------------------------------------------------------------------------
if [ -n "${STORE_ROOT}" ]; then
  echo "setup-dev-env: reprobuild store = ${DECISION} at ${STORE_ROOT} (${REASON})"
else
  echo "setup-dev-env: reprobuild store = ${DECISION} (${REASON})"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'decision=%s\n' "${DECISION}"
    printf 'store-root=%s\n' "${STORE_ROOT}"
    printf 'reason=%s\n' "${REASON}"
  } >>"${GITHUB_OUTPUT}"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### setup-dev-env: reprobuild store\n\n'
    printf -- '- store: **%s**\n' "${DECISION}"
    printf -- '- why: %s\n' "${REASON}"
  } >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
fi
