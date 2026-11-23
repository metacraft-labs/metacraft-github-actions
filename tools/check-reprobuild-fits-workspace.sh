#!/usr/bin/env bash
# Section 0b of metacraft-pm how-to-distribute-new-reprobuild-versions-internally.md:
# the `repro` a pin would install still fits the workspace.
#
# usage: tools/check-reprobuild-fits-workspace.sh <repro> <workspace-checkout>
#
# <workspace-checkout> is a disposable clone of metacraft-labs/repro-workspace.
# This script writes into it (the enabled-project state and the managed Git
# hooks), so never point it at a workspace someone uses.
#
# 1. It parses the manifests we actually have. Every project manifest under
#    projects/ is enabled without checking anything out, so that
#    `repro workspace status` reads all of them and every repo fragment they
#    name. It must exit 0, print no `error:` and list at least one repo. A
#    build older than a manifest field prints the schema error and, in some
#    builds, still exits 0, so the output is read, not only the status.
#    `repro workspace repos list --all --json` must then list every declared
#    repo fragment.
# 2. It answers the managed-hook contract. `repro hooks ensure --vcs` installs
#    the managed hooks into the clone; the contract id is taken from the
#    generated pre-push hook, and `repro hooks protocol --require=2
#    --hook-contract=<id>` must print `2` and exit 0.
#
# Exit status 0 when both hold, 1 when either does not, 2 on a usage error.
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: tools/check-reprobuild-fits-workspace.sh <repro> <workspace-checkout>" >&2
  exit 2
fi
repro=$1
workspace=$2
[ -x "$repro" ] || { echo "error: $repro is not an executable" >&2; exit 2; }
[ -d "$workspace/projects" ] && [ -d "$workspace/repos" ] \
  || { echo "error: $workspace is not a repro-workspace checkout" >&2; exit 2; }

fail() {
  echo "FAIL $*"
  exit 1
}

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cd "$workspace" || exit 2
"$repro" --version

projects=()
for file in projects/*.toml; do
  name=${file#projects/}
  projects+=("${name%.toml}")
done
[ "${#projects[@]}" -gt 0 ] || fail "$workspace has no project manifests"
"$repro" workspace enable --no-sync "${projects[@]}" >"$scratch/enable" 2>&1 \
  || { cat "$scratch/enable"; fail "repro workspace enable --no-sync refused the project manifests"; }

"$repro" workspace status >"$scratch/status" 2>&1
status=$?
cat "$scratch/status"
[ "$status" -eq 0 ] || fail "repro workspace status exited $status"
if grep -q 'error:' "$scratch/status"; then
  fail "repro workspace status reported an error (above)"
fi
summary=$(grep -E '^workspace status: summary ' "$scratch/status") \
  || fail "repro workspace status printed no summary"
listed=0
for field in $summary; do
  case $field in
    clean=* | dirty=* | missing=* | drifted=*) listed=$((listed + ${field#*=})) ;;
  esac
done
[ "$listed" -gt 0 ] || fail "repro workspace status listed no repos ($summary)"
echo "ok   repro workspace status read ${#projects[@]} project manifests and listed $listed repos"

"$repro" workspace repos list --all --json >"$scratch/repos.json" 2>"$scratch/repos.err" \
  || { cat "$scratch/repos.err"; fail "repro workspace repos list refused the repo fragments"; }
fragments=$(find repos -maxdepth 1 -name '*.toml' | wc -l)
declared=$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["repos"]))' \
  "$scratch/repos.json") || fail "repro workspace repos list printed no repo list"
[ "$declared" -eq "$fragments" ] \
  || fail "repro workspace repos list declared $declared repos for $fragments fragments"
echo "ok   repro workspace repos list read all $fragments repo fragments"

"$repro" hooks ensure --vcs . >"$scratch/hooks" 2>&1 \
  || { cat "$scratch/hooks"; fail "repro hooks ensure --vcs failed"; }
hook=$(git rev-parse --git-path hooks)/pre-push.repro-managed
[ -f "$hook" ] || fail "repro hooks ensure --vcs generated no $hook"
contract=$(grep -o -- '--hook-contract=[^[:space:]"'\'']*' "$hook" | sort -u)
contract=${contract#--hook-contract=}
[[ $contract =~ ^reprobuild\.managed-hook\.v[0-9]+\.pre-push\.[0-9a-f]+$ ]] \
  || fail "no single managed-hook contract in $hook: '$contract'"
answer=$("$repro" hooks protocol --require=2 --hook-contract="$contract")
status=$?
[ "$status" -eq 0 ] && [ "$answer" = 2 ] \
  || fail "repro hooks protocol --require=2 --hook-contract=$contract answered '$answer' (exit $status)"
echo "ok   repro answers the managed-hook contract $contract with protocol 2"
