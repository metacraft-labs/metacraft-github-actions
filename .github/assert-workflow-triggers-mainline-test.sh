#!/usr/bin/env bash
#
# assert-workflow-triggers-mainline-test.sh — contract suite for the
# mainline-trigger guard.
#
# The point of this file is the NEGATIVE cases, and specifically that they are
# REAL. A guard that cannot reject the state that shipped is decoration, so the
# fixtures below are not invented shapes — each one is the literal pre-fix
# `on:` block of a workflow that was silent on its own mainline, reproduced
# here verbatim:
#
#   1. this repository's OWN `test.yml` before it was corrected — the defect
#      that started this, on the shared-actions repo 64 others depend on;
#   2. `nim-acp/ci.yml` — `branches: [main]` in a repo that has no `main`,
#      the single most common shape (13 repositories had exactly this);
#   3. `nix-blockchain-development/ci.yml` — block-list `- main` where `main`
#      STILL EXISTS. This is the case a "does every named ref resolve?" check
#      passes forever, and it is why this guard asserts the mainline is
#      PRESENT rather than that the named branches are alive;
#   4. `codetracer/beam-flow.yml` — a `push:` filter with `paths:`, where the
#      naive fix is to rewrite the wrong key;
#   5. `codetracer-wasm-recorder/commit.yaml` — `paths-ignore:` on both `push:`
#      and `pull_request:`, quoted flow list;
#   6. `isonim-docs/ci.yml` — both `push:` and `pull_request:` filtered.
#
# and the POSITIVE cases that keep it usable: tag-only publish workflows, an
# unfiltered `pull_request:`, `branches:` appearing inside a step's `with:`,
# and the deliberate exemption.
#
# Needs no network: every case passes the mainline explicitly.
#
# Run:  bash .github/assert-workflow-triggers-mainline-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/assert-workflow-triggers-mainline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
	printf 'FAIL %s\n' "$1"
	shift
	[ "$#" -gt 0 ] && printf '     %s\n' "$@"
	failures=$((failures + 1))
}

n=0
write() { # <<heredoc  -> prints path
	n=$((n + 1))
	local f="$TMP/wf-${n}.yml"
	cat >"$f"
	printf '%s' "$f"
}

# expect_reject <label> <mainline> <file>
expect_reject() {
	local label="$1" mainline="$2" file="$3" out rc
	out="$(bash "$GUARD" "$mainline" "$file" 2>&1)"
	rc=$?
	if [ "$rc" -eq 1 ]; then
		pass "$label"
	else
		fail "$label — expected exit 1, got $rc" "$out"
	fi
}

# expect_accept <label> <mainline> <file>
expect_accept() {
	local label="$1" mainline="$2" file="$3" out rc
	out="$(bash "$GUARD" "$mainline" "$file" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		pass "$label"
	else
		fail "$label — expected exit 0, got $rc" "$out"
	fi
}

# ==== NEGATIVE: the real pre-fix files ======================================

# 1. This repository's own test.yml, as it stood before correction.
f="$(write <<'YAML'
name: test

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  resolve-sibling-rev:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
YAML
)"
expect_reject "rejects this repo's own pre-fix test.yml (mainline dev)" dev "$f"

# The diagnostic has to name the mainline and the workflow, or the person
# reading a red check learns nothing they did not already know.
out="$(bash "$GUARD" dev "$f" 2>&1)"
case "$out" in
*"does not name the mainline"*"dev"*) pass "the diagnostic names the mainline" ;;
*) fail "the diagnostic did not name the mainline" "$out" ;;
esac
case "$out" in
*"ci-mainline-exempt"*) pass "the diagnostic names the exemption escape hatch" ;;
*) fail "the diagnostic did not mention the exemption" "$out" ;;
esac

# 2. nim-acp/ci.yml — the commonest shape.
f="$(write <<'YAML'
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: eph-linux-x64
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects nim-acp/ci.yml pre-fix" dev "$f"

# 3. nix-blockchain-development/ci.yml — block list, and `main` really exists.
#    A liveness check on the named refs passes this forever.
f="$(write <<'YAML'
name: CI

on:
  workflow_dispatch:
  merge_group:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  lint:
    uses: metacraft-labs/nixos-modules/.github/workflows/reusable-lint.yml@main
YAML
)"
expect_reject "rejects a block list naming only a LIVE non-mainline branch" dev "$f"

# 4. codetracer/beam-flow.yml — push filter carrying `paths:`.
f="$(write <<'YAML'
name: beam-flow

on:
  pull_request:
    paths:
      - 'src/db-backend/**'
      - 'justfile'
  push:
    branches: [main]
    paths:
      - 'src/db-backend/**'
      - 'justfile'

jobs:
  beam:
    runs-on: eph-linux-x64
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects codetracer/beam-flow.yml pre-fix (push has paths:)" dev "$f"

# 5. codetracer-wasm-recorder/commit.yaml — paths-ignore on both events.
f="$(write <<'YAML'
name: commit
on:
  pull_request:
    branches: [main]
    paths-ignore:
      - '**/*.md'
      - 'site/**'
  push:
    branches: [main]
    paths-ignore:
      - '**/*.md'
      - 'site/**'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects codetracer-wasm-recorder/commit.yaml pre-fix" dev "$f"

# 6. isonim-docs/ci.yml — both events filtered.
f="$(write <<'YAML'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: eph-linux-x64
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects isonim-docs/ci.yml pre-fix" dev "$f"

# 7. Quoted flow list — codetracer-trace-format/rust.yml pre-fix.
f="$(write <<'YAML'
name: Rust
on:
  push:
    branches: ["master", "main"]
  pull_request:

jobs:
  lint:
    runs-on: eph-linux-x64
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects a quoted flow list that omits the mainline" dev "$f"

# 8. Non-`dev` mainlines: a spec repo and an infra repo.
f="$(write <<'YAML'
name: docs
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects a spec repo's workflow that omits \`latest\`" latest "$f"
expect_reject "rejects an infra repo's workflow that omits \`live\`" live "$f"
expect_reject "rejects a fork's workflow that omits \`codetracer\`" codetracer "$f"

# 9. branches-ignore reaching the same place by the other door.
f="$(write <<'YAML'
name: CI
on:
  push:
    branches-ignore:
      - dev
      - 'wip/**'
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects a branches-ignore that excludes the mainline" dev "$f"

# ==== POSITIVE: the shapes that must keep working ==========================

# The corrected forms of the fixtures above.
f="$(write <<'YAML'
name: CI
on:
  push:
    branches: [dev, stable]
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts the corrected flow list" dev "$f"

f="$(write <<'YAML'
name: CI
on:
  push:
    branches:
      - main
      - dev
      - stable
  pull_request:
    branches:
      - main
      - dev
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts a block list that keeps a live \`main\` and adds the mainline" dev "$f"

# A tag-keyed publish workflow is correct as written.
f="$(write <<'YAML'
name: publish-npm
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+*'
  workflow_dispatch:
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts a tag-only publish workflow" dev "$f"

f="$(write <<'YAML'
name: release
on:
  push:
    tags: 'v*'
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts an inline scalar tags: filter" dev "$f"

# No branch filter at all: unrestricted, so it already runs on the mainline.
f="$(write <<'YAML'
name: CI
on:
  push:
  pull_request:
  workflow_dispatch:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts an unfiltered push/pull_request" dev "$f"

# `on:` as a scalar and as a flow sequence.
f="$(write <<'YAML'
name: CI
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts \`on: push\`" dev "$f"

f="$(write <<'YAML'
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts \`on: [push, pull_request]\`" dev "$f"

# A glob that covers the mainline.
f="$(write <<'YAML'
name: CI
on:
  push:
    branches: ['*']
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts a glob that matches the mainline" dev "$f"

# THE FALSE-POSITIVE TRAP: `branches:` inside a step's `with:` must not be
# mistaken for a trigger filter. A guard that fired here would be switched off.
f="$(write <<'YAML'
name: CI
on:
  push:
    branches: [dev]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: some/action@v1
        with:
          branches: [main]
          branches-ignore: [dev]
YAML
)"
expect_accept "does not mistake a step's \`with: branches:\` for a trigger" dev "$f"

# `on:` quoted, which YAML 1.1 users write to stop `on` parsing as true.
f="$(write <<'YAML'
name: CI
"on":
  push:
    branches: [dev]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "handles a quoted \`\"on\":\` key" dev "$f"

f="$(write <<'YAML'
name: CI
"on":
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "still rejects under a quoted \`\"on\":\` key" dev "$f"

# ==== The exemption ========================================================

# codetracer/deploy-web-codetracer.yml is the real case: a deploy that belongs
# to one environment branch and must NOT run on the mainline.
f="$(write <<'YAML'
name: deploy-web-codetracer

# ci-mainline-exempt: deploys the hosted app; `cloud` is the deploy branch and
# a mainline push must not reach production.

on:
  push:
    branches: [cloud]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_accept "accepts a deliberately-scoped deploy carrying a reasoned exemption" dev "$f"

# A marker with no reason is not a decision.
f="$(write <<'YAML'
name: deploy
# ci-mainline-exempt:
on:
  push:
    branches: [cloud]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
)"
expect_reject "rejects an exemption with no reason" dev "$f"

# ==== Operational behaviour ================================================

# Handed a file that does not exist, the guard must fail loudly.
out="$(bash "$GUARD" dev "$TMP/nope.yml" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
	pass "a missing file is exit 2, not a pass"
else
	fail "a missing file should be exit 2, got $rc" "$out"
fi

# Asked to scan a repo with no workflows, it must fail loudly rather than
# report a vacuous success.
empty="$TMP/empty/.github"
mkdir -p "$empty"
cp "$GUARD" "$empty/"
out="$(bash "$empty/assert-workflow-triggers-mainline.sh" dev 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
	pass "no workflows at all is exit 2, not a vacuous pass"
else
	fail "no workflows should be exit 2, got $rc" "$out"
fi

# Refuses to guess a mainline when it cannot detect one.
mkdir -p "$TMP/norepo/.github/workflows"
cp "$GUARD" "$TMP/norepo/.github/"
cat >"$TMP/norepo/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [main]
YAML
out="$(cd "$TMP/norepo" && bash .github/assert-workflow-triggers-mainline.sh 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
	pass "refuses to guess a mainline outside a repo with branches"
else
	fail "should refuse to guess a mainline, got $rc" "$out"
fi

# Detects the mainline from the branches that exist, in policy order.
detect_repo="$TMP/detect"
mkdir -p "$detect_repo/.github/workflows"
cp "$GUARD" "$detect_repo/.github/"
cat >"$detect_repo/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [dev]
YAML
(
	cd "$detect_repo" || exit 1
	git init -q . 2>/dev/null
	git config user.email t@e.st
	git config user.name t
	git add -A >/dev/null 2>&1
	git commit -qm x >/dev/null 2>&1
	git branch -q dev 2>/dev/null
	git remote add origin "$detect_repo/.git" 2>/dev/null
) >/dev/null 2>&1
out="$(cd "$detect_repo" && bash .github/assert-workflow-triggers-mainline.sh 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "${out#*dev}" != "$out" ]; then
	pass "detects \`dev\` from the branches that exist"
else
	fail "should have detected \`dev\` (exit $rc)" "$out"
fi

# The composite action runs the guard from ITS OWN checkout against SOMEBODY
# ELSE'S tree, which only works if the root can be pointed elsewhere. Without
# this, the action would silently inspect the wrong repository's workflows —
# and pass, because this repository's own workflows are clean.
other="$TMP/other"
mkdir -p "$other/.github/workflows"
cat >"$other/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [main]
YAML
out="$(WORKFLOW_TRIGGERS_ROOT="$other" bash "$GUARD" dev 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
	pass "WORKFLOW_TRIGGERS_ROOT inspects the named tree, not the script's own"
else
	fail "WORKFLOW_TRIGGERS_ROOT should have found the other tree's defect (exit $rc)" "$out"
fi
case "$out" in
*"ci.yml"*) pass "the diagnostic names the other tree's file" ;;
*) fail "the diagnostic did not name the other tree's file" "$out" ;;
esac

# ==== This repository's own workflows must pass ============================
out="$(bash "$GUARD" dev 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "this repository's own workflows name the mainline"
else
	fail "this repository's workflows should pass (exit $rc)" "$out"
fi
case "$out" in
*"name the mainline"*) pass "the pass path reports a count" ;;
*) fail "the pass path did not report a count" "$out" ;;
esac

# ===========================================================================
if [ "$failures" -eq 0 ]; then
	echo "assert-workflow-triggers-mainline-test: all cases pass."
	exit 0
fi
echo "assert-workflow-triggers-mainline-test: ${failures} case(s) failed."
exit 1
