#!/usr/bin/env bash
#
# sibling-strategy-step-test.sh — contract suite for the two steps that decide
# and execute setup-dev-env's cross-repo sibling provisioning:
#
#   ./decide-sibling-strategy.sh        which mechanism, and why
#   ./provision-siblings-from-lock.sh   the repro.lock path, and its evidence
#
# WHY THIS SUITE EXISTS
# ---------------------
# Both scripts exist because picking the mechanism BY HAND went wrong in a way
# nothing could see. A consumer hand-wrote nine siblings through
# `clone-siblings`; five were in its `repro.lock` and four were a DEPENDENCY's
# siblings that no lock could ever pin. The hard failure took out ~15 jobs on
# every pull request, and the first fix silently un-pinned the four the lock
# had been pinning correctly.
#
# The fix for that class of bug is a decision that is made from evidence and
# then SAID OUT LOUD. So most of what this suite asserts is not "the right
# thing happened" but "the right thing happened AND the log says which and
# why" — an auto-detection that is right for a reason nobody can read is the
# same failure with a different shape.
#
# THE ONE MOCK, AND WHY IT IS ONE
# -------------------------------
# `repro` is stubbed. Everything else is real: real files, real bash, the real
# shipped scripts, the real action.yml.
#
# The stub is unavoidable and it is scoped to one thing. `repro` is a compiled
# Nim binary from another repository; the runner this suite is written for is
# stock `ubuntu-latest` with bash and git and nothing else, chosen so that a
# guard does not share the failure modes of what it guards (see
# .github/workflows/test.yml). Building reprobuild here to test a routing
# decision would give this suite a dependency on the toolchain whose
# provisioning it is checking.
#
# What keeps the stub honest is that it does not INVENT its answers. The two
# central fixtures below are verbatim captures of `repro develop --list --json`
# from real repositories — one with a committed lock resolving five siblings at
# exact SHAs, one with no committed lock at all — and every other fixture is
# one of those two with a single field changed, so each contract states exactly
# which field it turns on. The stub's own behaviour (which subcommand it saw,
# what it wrote where) is asserted too, so a script that stopped invoking
# `repro develop --all` would fail here rather than pass quietly.
#
# MUTATION-VERIFIED. Every rule this suite exists to protect was verified by
# removing it from the shipped script and re-running, so none of these
# contracts is a tautology over behaviour that was never in question:
#
#   count every `deps` entry, not just `path != "."`     -> 7 failures
#   forced `repro-lock` falls back instead of refusing   -> 8 failures
#   `auto` stops gating on env-flavor                    -> 4 failures
#   `auto` stops honouring a hand-declared sibling list  -> 5 failures
#   accept a pin from any backend, not just the lock     -> 6 failures
#   accept a `revision` that is not a commit SHA         -> 6 failures
#   assume a two-space indent instead of deriving it     -> 1 failure
#
# The individual sections quote the messages the mutations produced.
#
# Run: bash setup-dev-env/sibling-strategy-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$HERE/action.yml"
DECIDE="$HERE/decide-sibling-strategy.sh"
PROVISION="$HERE/provision-siblings-from-lock.sh"

for f in "$ACTION" "$DECIDE" "$PROVISION"; do
	[[ -f $f ]] || {
		echo "sibling-strategy-step-test: cannot find $f" >&2
		exit 2
	}
done
bash -n "$DECIDE" || exit 2
bash -n "$PROVISION" || exit 2

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL $1"
	[[ -n ${2:-} ]] && echo "     $2"
}
check() { # <desc> <actual> <expected>
	if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}
contains() { # <desc> <haystack> <needle>
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "did not contain [$3]" ;;
	esac
}
lacks() { # <desc> <haystack> <needle>
	case "$2" in
	*"$3"*) bad "$1" "unexpectedly contained [$3]" ;;
	*) ok "$1" ;;
	esac
}

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

WS="$TMPROOT/ws/consumer"
OUTFILE="$TMPROOT/github-output"
SUMFILE="$TMPROOT/step-summary.md"
BIN="$TMPROOT/bin"
mkdir -p "$BIN"

OUT=""
RC=0

# `out_of <key>` — read a single-line `key=value` from the step's GITHUB_OUTPUT.
out_of() {
	local k="$1" line
	while IFS= read -r line || [[ -n $line ]]; do
		case "$line" in
		"$k="*)
			printf '%s' "${line#"$k="}"
			return 0
			;;
		esac
	done <"$OUTFILE"
	return 0
}

# `block_of <key>` — read a heredoc-delimited multi-line output value.
block_of() {
	local k="$1" line inside=0 acc=""
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $inside -eq 1 ]]; then
			[[ $line == "__SETUP_DEV_ENV_EOF__" ]] && break
			acc="${acc}${line}"$'\n'
			continue
		fi
		[[ $line == "$k<<__SETUP_DEV_ENV_EOF__" ]] && inside=1
	done <"$OUTFILE"
	printf '%s' "$acc"
}

# ===========================================================================
# 1. The action must actually run these scripts, with these inputs.
#
# This suite executes the shipped files directly. Without the checks below it
# would keep passing while action.yml invoked something else, or invoked them
# with an `env:` entry that had been dropped in a refactor — a green suite
# exercising a program nothing runs.
# ===========================================================================
ACTION_TEXT="$(<"$ACTION")"

contains "action.yml runs decide-sibling-strategy.sh" "$ACTION_TEXT" \
	'run: bash "${GITHUB_ACTION_PATH}/decide-sibling-strategy.sh"'
contains "action.yml runs provision-siblings-from-lock.sh" "$ACTION_TEXT" \
	'run: bash "${GITHUB_ACTION_PATH}/provision-siblings-from-lock.sh"'

for v in SIBLING_STRATEGY ENV_FLAVOR SIBLINGS_INPUT; do
	contains "decide step declares $v in env:" "$ACTION_TEXT" "        ${v}: "
done

contains "the sibling-strategy input exists" "$ACTION_TEXT" "  sibling-strategy:"
contains "sibling-strategy defaults to auto" "$ACTION_TEXT" '    default: "auto"'
contains "the decide step carries the id the later ifs reference" "$ACTION_TEXT" \
	"      id: sibling-strategy"
contains "the repro-lock step carries the id the late clone references" "$ACTION_TEXT" \
	"      id: repro-siblings"

# The gating expressions. A dropped `if:` here is not a test failure in this
# repo — it is both mechanisms running in one job, or neither.
contains "clone-siblings is skipped only on the repro path" "$ACTION_TEXT" \
	"if: \${{ steps.sibling-strategy.outputs.strategy != 'repro-lock' }}"
contains "the repro.lock step runs only on the repro path" "$ACTION_TEXT" \
	"if: \${{ steps.sibling-strategy.outputs.strategy == 'repro-lock' }}"
contains "the late clone runs only when the repro path asked for it" "$ACTION_TEXT" \
	"steps.repro-siblings.outputs.late-clone == 'true'"
# A forced repro-lock under a non-reprobuild flavor must still get the CLI, or
# the step below it can only ever report "repro is not on PATH".
contains "the repro CLI is installed for a forced repro-lock under any flavor" "$ACTION_TEXT" \
	"if: \${{ inputs.env-flavor == 'reprobuild' || steps.sibling-strategy.outputs.strategy == 'repro-lock' }}"

# ===========================================================================
# 2. Fixtures.
# ===========================================================================
new_ws() {
	rm -rf "$TMPROOT/ws"
	mkdir -p "$WS/.github"
	: >"$OUTFILE"
	: >"$SUMFILE"
}

# A solved-graph lock in the shape `repro lock` writes: one `deps = [...]`
# line of inline tables, the consumer itself carried as `path = "."`.
put_lock() { # <deps-inline-tables>
	{
		printf 'schema = "reprobuild.solved-graph-lock.v2"\n\n'
		printf '[lock]\nplatform = "amd64-linux"\noptimal = true\n'
		printf 'inputs_digest = "fnv1a64:5f8f62ac9d7bf36c"\n'
		printf 'packages = [{ name = "attic-client", version = "0.0.0", source = "attic-client" }]\n'
		printf 'deps = [%s]\n' "$1"
	} >"$WS/repro.lock"
}
DEP_SELF='{ name = "consumer", path = ".", coord_kind = "vcs", revision = "e2c85e9b47003153ed6df5dde66266233f961501" }'
DEP_ISONIM='{ name = "isonim", path = "../isonim", coord_kind = "vcs", revision = "e82b819d2d05efb6023a966e886fdbec6d1660cb" }'
DEP_NIMACP='{ name = "nim-acp", path = "../nim-acp", coord_kind = "vcs", revision = "5097adb4b6827dea2e1a7e580a496a7160507b76" }'

lock_with_siblings() { put_lock "${DEP_SELF}, ${DEP_ISONIM}, ${DEP_NIMACP}"; }
lock_root_only() { put_lock "${DEP_SELF}"; }
lock_foreign() { printf 'schema = "something.else.v1"\n\ndeps = [%s]\n' "${DEP_ISONIM}" >"$WS/repro.lock"; }

# ---------------------------------------------------------------------------
# The two verbatim `repro develop --list --json` captures.
# ---------------------------------------------------------------------------
# LIST_OK is `codetracer`'s: a committed lock resolving five siblings, each
# pinned to an exact SHA, every row attributed to the `committed-lock` backend.
LIST_OK="$TMPROOT/list-ok.json"
cat >"$LIST_OK" <<'JSON'
{
  "schemaId": "reprobuild.develop-list.v1",
  "workspaceRoot": "/w/consumer",
  "repos": [
    {
      "name": "isonim",
      "tier": "public",
      "backend": "committed-lock",
      "revision": "e82b819d2d05efb6023a966e886fdbec6d1660cb",
      "path": "/w/isonim",
      "state": "develop"
    },
    {
      "name": "nim-acp",
      "tier": "public",
      "backend": "committed-lock",
      "revision": "5097adb4b6827dea2e1a7e580a496a7160507b76",
      "path": "/w/nim-acp",
      "state": "develop"
    },
    {
      "name": "nim-agent-harbor",
      "tier": "public",
      "backend": "committed-lock",
      "revision": "e95cae45e6c316bed492955153e1e4fcb4dfca1f",
      "path": "/w/nim-agent-harbor",
      "state": "develop"
    },
    {
      "name": "nim-agents",
      "tier": "public",
      "backend": "committed-lock",
      "revision": "348c7ca4ad0298a7e0b2041a4ddeb8d61c630150",
      "path": "/w/nim-agents",
      "state": "develop"
    },
    {
      "name": "nim-everywhere",
      "tier": "public",
      "backend": "committed-lock",
      "revision": "5ac622ca0acce054089fb9204fd18eea8354cd3f",
      "path": "/w/nim-everywhere",
      "state": "develop"
    }
  ],
  "backends": [
    {
      "tier": "public",
      "kind": "committed-lock",
      "location": "/w/consumer/repro.lock",
      "reachable": true,
      "records": 6,
      "adhoc": false,
      "excluded": false,
      "repos": []
    }
  ],
  "selection": [
    {
      "stage": "mode",
      "flag": "--all",
      "kept": 5
    }
  ],
  "notices": [],
  "errors": [],
  "exitCode": 0
}
JSON

# LIST_NO_LOCK is `infra`'s: no committed lock at all. Note the shape — this is
# NOT a crash. It is a well-formed document with an empty repo set, an
# unreachable backend carrying a diagnostic, and exitCode 1. A detector that
# keyed on "did the command produce JSON" would accept it.
LIST_NO_LOCK="$TMPROOT/list-no-lock.json"
cat >"$LIST_NO_LOCK" <<'JSON'
{
  "schemaId": "reprobuild.develop-list.v1",
  "workspaceRoot": "/w/consumer",
  "repos": [],
  "backends": [
    {
      "tier": "public",
      "kind": "committed-lock",
      "location": "/w/consumer/repro.lock",
      "reachable": false,
      "records": 0,
      "adhoc": false,
      "excluded": false,
      "diagnostic": "no committed lock at /w/consumer/repro.lock",
      "repos": []
    }
  ],
  "selection": [],
  "notices": [],
  "errors": [
    {
      "node": "*",
      "diagnostic": "the workspace lock set at /w/consumer is EMPTY: no lock backend readable from this workspace yielded a single lock record."
    }
  ],
  "exitCode": 1
}
JSON

# Derivations, each one field away from LIST_OK, so a contract that fires on
# one of them names exactly the field it is about.
mutate_list() { # <dest> <sed-free bash replacement: from> <to>
	local dest="$1" from="$2" to="$3" line
	: >"$dest"
	while IFS= read -r line || [[ -n $line ]]; do
		printf '%s\n' "${line//"$from"/"$to"}" >>"$dest"
	done <"$LIST_OK"
}

LIST_UNPINNED="$TMPROOT/list-unpinned.json"
mutate_list "$LIST_UNPINNED" '"revision": "5097adb4b6827dea2e1a7e580a496a7160507b76"' '"revision": "dev"'

# The fourth row's backend only: `nim-agents` pinned by a routed manifests
# checkout while every other row still comes from the committed lock. This is
# the mixed-provenance case, and it has to be built positionally because the
# line itself is identical in all five rows.
LIST_MIXED="$TMPROOT/list-mixed.json"
{
	_seen=0
	while IFS= read -r _l || [[ -n $_l ]]; do
		if [[ $_l == '      "backend": "committed-lock",' ]]; then
			_seen=$((_seen + 1))
			if [[ $_seen -eq 4 ]]; then
				printf '      "backend": "git-checkout",\n'
				continue
			fi
		fi
		printf '%s\n' "$_l"
	done <"$LIST_OK"
} >"$LIST_MIXED"

LIST_NO_RECORDS="$TMPROOT/list-no-records.json"
mutate_list "$LIST_NO_RECORDS" '"records": 6' '"records": 0'

LIST_BAD_SCHEMA="$TMPROOT/list-bad-schema.json"
mutate_list "$LIST_BAD_SCHEMA" '"reprobuild.develop-list.v1"' '"reprobuild.develop-list.v9"'

# Four-space pretty printing of the same document. The reader derives its
# indent step from the first indented line rather than assuming two spaces;
# without that, a formatter change in `repro` would silently stop matching and
# every repo in the fleet would fall back with "could not read as a
# develop-list document".
LIST_INDENT4="$TMPROOT/list-indent4.json"
{
	while IFS= read -r _l || [[ -n $_l ]]; do
		_t="${_l#"${_l%%[![:space:]]*}"}"
		_n=$((${#_l} - ${#_t}))
		_pad=""
		_k=0
		while [[ $_k -lt $((_n * 2)) ]]; do
			_pad="$_pad "
			_k=$((_k + 1))
		done
		printf '%s%s\n' "$_pad" "$_t"
	done <"$LIST_OK"
} >"$LIST_INDENT4"

# Not a document at all — what the CLI prints when it rejects the invocation.
LIST_GARBAGE="$TMPROOT/list-garbage.json"
printf 'repro develop: error: unsupported develop flag: --list\n' >"$LIST_GARBAGE"

# ---------------------------------------------------------------------------
# The `repro` stub. See the header for why this is the one mock.
# ---------------------------------------------------------------------------
ALL_MARKER="$TMPROOT/develop-all-ran"
cat >"$BIN/repro" <<'SHIM'
#!/usr/bin/env bash
mode=""
for a in "$@"; do
  case "$a" in
    --list) mode=list ;;
    --all)  mode=all ;;
  esac
done
case "$mode" in
  list)
    [ -n "${REPRO_FAKE_LIST_STDERR:-}" ] && printf '%s\n' "$REPRO_FAKE_LIST_STDERR" >&2
    while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done <"$REPRO_FAKE_LIST_JSON"
    exit "${REPRO_FAKE_LIST_RC:-0}"
    ;;
  all)
    printf 'develop --all in %s\n' "$PWD" >>"$REPRO_FAKE_ALL_MARKER"
    exit "${REPRO_FAKE_ALL_RC:-0}"
    ;;
esac
printf 'repro: unexpected invocation: %s\n' "$*" >&2
exit 1
SHIM
chmod +x "$BIN/repro"

# ===========================================================================
# 3. Drivers.
# ===========================================================================
run_decide() { # <sibling-strategy> <env-flavor> <siblings-input>
	: >"$OUTFILE"
	: >"$SUMFILE"
	OUT="$(
		SIBLING_STRATEGY="$1" \
			ENV_FLAVOR="$2" \
			SIBLINGS_INPUT="$3" \
			GITHUB_WORKSPACE="$WS" \
			GITHUB_OUTPUT="$OUTFILE" \
			GITHUB_STEP_SUMMARY="$SUMFILE" \
			bash "$DECIDE" 2>&1
	)"
	RC=$?
	[[ -n ${SHOW_STEP_OUTPUT:-} ]] && {
		echo "--- decide strategy=$1 flavor=$2 siblings=[${3//$'\n'/ }] rc=$RC ---"
		echo "$OUT"
		echo "--- end ---"
	}
	return 0
}

run_provision() { # <sibling-strategy> <siblings-input> <list-json> [<list-rc>] [<all-rc>]
	: >"$OUTFILE"
	: >"$SUMFILE"
	: >"$ALL_MARKER"
	OUT="$(
		PATH="$BIN:$PATH" \
			SIBLING_STRATEGY="$1" \
			SIBLINGS_INPUT="$2" \
			GITHUB_WORKSPACE="$WS" \
			GITHUB_OUTPUT="$OUTFILE" \
			GITHUB_STEP_SUMMARY="$SUMFILE" \
			RUNNER_TEMP="$TMPROOT" \
			REPRO_FAKE_LIST_JSON="$3" \
			REPRO_FAKE_LIST_RC="${4:-0}" \
			REPRO_FAKE_ALL_RC="${5:-0}" \
			REPRO_FAKE_ALL_MARKER="$ALL_MARKER" \
			bash "$PROVISION" 2>&1
	)"
	RC=$?
	[[ -n ${SHOW_STEP_OUTPUT:-} ]] && {
		echo "--- provision strategy=$1 siblings=[${2//$'\n'/ }] rc=$RC ---"
		echo "$OUT"
		echo "--- end ---"
	}
	return 0
}

echo
echo "== decide-sibling-strategy.sh =="

# ===========================================================================
# 4. `auto` without a usable lock keeps today's behaviour.
#
# This is the backward-compatibility contract, and it is the one that matters
# most: this action is consumed at `@main` by every repo in the org, so a
# caller that passes nothing must reach `clone-siblings` exactly as it does
# today. Every repo in the fleet that has no committed lock — which is most of
# them, including all sixteen recorder repos — lands here.
# ===========================================================================
new_ws
run_decide auto reprobuild ""
check "auto without a repro.lock chooses clone-siblings" "$(out_of strategy)" "clone-siblings"
check "  and exits 0" "$RC" "0"
contains "  and says there is no repro.lock" "$OUT" "there is no repro.lock"
contains "  on one line, in the shape every path uses" "$OUT" "setup-dev-env: sibling provisioning = clone-siblings ("
contains "  and in the job summary" "$(<"$SUMFILE")" "strategy: **clone-siblings**"

# A file that is not a solved-graph lock is not a lock. Existence is not the
# test; this is the "not just file existence" contract.
new_ws
lock_foreign
run_decide auto reprobuild ""
check "a repro.lock with a foreign schema chooses clone-siblings" "$(out_of strategy)" "clone-siblings"
contains "  and says the schema is not a solved-graph lock" "$OUT" "declares no reprobuild.solved-graph-lock schema"

# ===========================================================================
# 5. `auto` with a usable lock takes the repro path — and the sibling COUNT is
#    what makes it usable, not the file.
#
# MUTATION. The two cases below differ by one inline table in `deps`. Deleting
# the `path = "."` exclusion from decide-sibling-strategy.sh makes the
# root-only lock report `LOCK_SIBLINGS=1` and take the repro path, at which
# point `repro develop --all` has nothing to provision and the job silently
# stops cloning the siblings clone-siblings used to fetch. Observed:
#   "ok   a root-only repro.lock chooses clone-siblings" became
#   "FAIL a root-only repro.lock chooses clone-siblings: expected
#    [clone-siblings], got [repro-lock]".
# ===========================================================================
new_ws
lock_with_siblings
run_decide auto reprobuild ""
check "a lock pinning siblings chooses repro-lock" "$(out_of strategy)" "repro-lock"
check "  and counts only the non-root deps" "$(out_of lock-siblings)" "2"
contains "  and says so" "$OUT" "repro.lock pins 2 sibling dependencies"

new_ws
lock_root_only
run_decide auto reprobuild ""
check "a root-only repro.lock chooses clone-siblings" "$(out_of strategy)" "clone-siblings"
check "  and counts zero siblings" "$(out_of lock-siblings)" "0"
contains "  and says every dep is the consumer itself" "$OUT" 'every dep is path = "."'

# ===========================================================================
# 6. `auto` will not take the repro path under a flavor that has no repro CLI.
#
# The repro path needs the CLI, and `reprobuild` is the one flavor where this
# action installs it anyway. Choosing the repro path for a `nix` job would add
# a from-source CLI build to it — which is a decision a caller may make, and
# `auto` may not make on that caller's behalf.
# ===========================================================================
new_ws
lock_with_siblings
run_decide auto nix ""
check "auto declines the repro path under env-flavor: nix" "$(out_of strategy)" "clone-siblings"
contains "  and names the flavor as the reason" "$OUT" "env-flavor is 'nix'"
contains "  and names the override that would change it" "$OUT" "set sibling-strategy: repro-lock"

new_ws
lock_with_siblings
run_decide auto windows-diy ""
check "auto declines the repro path under env-flavor: windows-diy" "$(out_of strategy)" "clone-siblings"

# ===========================================================================
# 7. `auto` does not override a hand-declared sibling list.
#
# Those lists are not noise: `reprobuild`'s own names two repos its build needs
# that are absent from every committed lock. Switching such a caller to "the
# lock is authoritative" would drop them. So the list wins, and the log says
# the lock was available and was not used — the input is honoured, never
# silently ignored in either direction.
# ===========================================================================
new_ws
lock_with_siblings
run_decide auto reprobuild "codetracer-trace-format"$'\n'"codetracer-native-recorder"
check "a declared siblings: input keeps clone-siblings" "$(out_of strategy)" "clone-siblings"
check "  and both entries are counted" "$(out_of declared-siblings)" "2"
contains "  and the reason names the input" "$OUT" "declares 2 of its own in the 'siblings' input"
contains "  and still reports the lock was there" "$OUT" "repro.lock pins 2 siblings, but"

new_ws
lock_with_siblings
printf '# a comment\nisonim-render-serve\nnim-acp\n' >"$WS/.github/sibling-repos"
run_decide auto reprobuild ""
check "a non-empty .github/sibling-repos keeps clone-siblings" "$(out_of strategy)" "clone-siblings"
check "  counting entries, not lines" "$(out_of declared-siblings)" "2"
contains "  and the reason names the file" "$OUT" "declares 2 of its own in .github/sibling-repos"

# The stub file most of the fleet carries: comments only, declaring nothing.
# Treating its mere existence as a declaration would pin every such repo to
# clone-siblings forever.
new_ws
lock_with_siblings
printf '# Cross-repo siblings cloned by setup-dev-env at workspace-lock-pinned\n# revisions.\n' \
	>"$WS/.github/sibling-repos"
run_decide auto reprobuild ""
check "a comment-only .github/sibling-repos declares nothing" "$(out_of declared-siblings)" "0"
check "  so the repro path is taken" "$(out_of strategy)" "repro-lock"

# ===========================================================================
# 8. The override forces both directions, and never quietly does nothing.
#
# MUTATION. Letting a forced `repro-lock` fall through to clone-siblings when
# there is no usable lock — the "helpful" reading of an override — produced 8
# failures here, starting with "FAIL forced repro-lock without a lock fails:
# expected [1], got [0]". That is the whole point of the input: a caller who
# writes `repro-lock` and gets manifest resolution anyway has been told
# nothing.
# ===========================================================================
new_ws
lock_with_siblings
run_decide clone-siblings reprobuild ""
check "forced clone-siblings wins over a usable lock" "$(out_of strategy)" "clone-siblings"
contains "  and says it was forced" "$OUT" "forced by sibling-strategy: clone-siblings"

new_ws
lock_with_siblings
run_decide repro-lock nix ""
check "forced repro-lock ignores the flavor gate" "$(out_of strategy)" "repro-lock"
check "  and exits 0" "$RC" "0"

# The contract the operator asked for by name: a forced repro-lock on a repo
# with no usable lock FAILS, rather than quietly resolving from the very
# manifests the caller was trying to stop using.
new_ws
run_decide repro-lock reprobuild ""
check "forced repro-lock without a lock fails" "$RC" "1"
contains "  with an ::error::" "$OUT" "::error::setup-dev-env: sibling-strategy: repro-lock was requested"
contains "  naming what is missing" "$OUT" "there is no repro.lock"
contains "  and refusing the silent fallback" "$OUT" "NOT quietly fall back to clone-siblings"
contains "  and naming both ways out" "$OUT" "sibling-strategy: auto"

new_ws
lock_root_only
run_decide repro-lock reprobuild ""
check "forced repro-lock on a root-only lock fails" "$RC" "1"
contains "  naming the reason precisely" "$OUT" "pins no sibling dependency"

new_ws
lock_foreign
run_decide repro-lock reprobuild ""
check "forced repro-lock on a foreign schema fails" "$RC" "1"

new_ws
run_decide sometimes reprobuild ""
check "an unknown sibling-strategy fails" "$RC" "1"
contains "  listing the accepted values" "$OUT" "auto, repro-lock, clone-siblings"

echo
echo "== provision-siblings-from-lock.sh =="

# ===========================================================================
# 9. The happy path: the lock is read, the pins are shown, --all runs.
# ===========================================================================
new_ws
lock_with_siblings
run_provision auto "" "$LIST_OK"
check "a committed-lock document provisions from the lock" "$RC" "0"
contains "  reporting the path on one line" "$OUT" "setup-dev-env: sibling provisioning = repro-lock ("
contains "  with the count" "$OUT" "repro.lock pinned 5 siblings at exact commits"
contains "  and the resolution table, by name and SHA" "$OUT" "isonim                           e82b819d2d05efb6023a966e886fdbec6d1660cb"
contains "  naming nim-agent-harbor too" "$OUT" "nim-agent-harbor                 e95cae45e6c316bed492955153e1e4fcb4dfca1f"
contains "  and the job summary says which path ran" "$(<"$SUMFILE")" "sibling provisioning: **repro-lock**"
contains "  and repro develop --all actually ran, in the workspace" "$(<"$ALL_MARKER")" "develop --all in $WS"
check "  with no follow-on clone" "$(out_of late-clone)" "false"

# ===========================================================================
# 10. `auto` falls back when the evidence does not hold; forced fails.
#
# Every case below is a DIFFERENT way for a lock to look present and not be
# usable, and each is one field away from the document above. A detector that
# only checked "the file exists" or "the command produced JSON" would accept
# all of them.
#
# MUTATION, twice. Dropping the per-repo `backend == "committed-lock"` check
# produced 6 failures led by "FAIL auto falls back: a pin supplied by a routed
# store — expected [true], got [false]", with `repro develop --all` observed to
# have run against a half-manifest-resolved set. Dropping the 40-hex `revision`
# check produced 6 more, led by the same shape on the unpinned document. Both
# are the false-positive the operator asked about: a lock that is present and
# partial.
# ===========================================================================
provision_case() { # <desc> <list-json> <list-rc> <needle>
	new_ws
	lock_with_siblings
	run_provision auto "" "$2" "$3"
	check "auto falls back: $1" "$(out_of late-clone)" "true"
	check "  exiting 0, because auto must not turn a green fleet red" "$RC" "0"
	contains "  with a ::warning:: naming the reason" "$OUT" "::warning::setup-dev-env: falling back to clone-siblings"
	contains "  the reason being: $1" "$OUT" "$4"
	contains "  and one line saying which path ran" "$OUT" "sibling provisioning = clone-siblings (auto fell back:"
	lacks "  and repro develop --all was not run" "$(<"$ALL_MARKER")" "develop --all"

	new_ws
	lock_with_siblings
	run_provision repro-lock "" "$2" "$3"
	check "forced repro-lock fails instead: $1" "$RC" "1"
	contains "  with an ::error::" "$OUT" "::error::setup-dev-env: sibling-strategy: repro-lock was requested, but"
	contains "  refusing the silent fallback" "$OUT" "will not silently fall back to clone-siblings"
}

provision_case "no committed lock (the real infra document)" "$LIST_NO_LOCK" 1 \
	"the workspace lock set at /w/consumer is EMPTY"
provision_case "a dependency named but not pinned to a commit" "$LIST_UNPINNED" 0 \
	"'nim-acp' is not pinned to a commit SHA by the committed lock (revision 'dev')"
provision_case "a pin supplied by a routed store, not this repo's lock" "$LIST_MIXED" 0 \
	"'nim-agents' is pinned by the 'git-checkout' backend"
provision_case "the committed-lock backend contributed no records" "$LIST_NO_RECORDS" 0 \
	"no reachable committed-lock backend contributed a record"
provision_case "an unrecognised document schema" "$LIST_BAD_SCHEMA" 0 \
	"reported schemaId 'reprobuild.develop-list.v9'"
provision_case "output that is not a document at all" "$LIST_GARBAGE" 1 \
	"could not read as a develop-list document"

# The CLI absent entirely — the case a nix-flavor job would hit if the install
# steps' `if:` ever stopped covering a forced repro-lock.
new_ws
lock_with_siblings
: >"$OUTFILE"
: >"$SUMFILE"
: >"$ALL_MARKER"
# An EMPTY PATH, and bash by absolute path so the invocation itself still
# works. The script needs no external command other than `repro`, which is the
# whole point of the contract.
mkdir -p "$TMPROOT/empty-bin"
REAL_BASH="$(command -v bash)"
OUT="$(
	PATH="$TMPROOT/empty-bin" SIBLING_STRATEGY=auto SIBLINGS_INPUT="" \
		GITHUB_WORKSPACE="$WS" GITHUB_OUTPUT="$OUTFILE" GITHUB_STEP_SUMMARY="$SUMFILE" \
		RUNNER_TEMP="$TMPROOT" "$REAL_BASH" "$PROVISION" 2>&1
)"
RC=$?
check "auto falls back when the repro CLI is absent" "$(out_of late-clone)" "true"
check "  exiting 0" "$RC" "0"
contains "  saying so" "$OUT" "the 'repro' CLI is not on PATH"

# ===========================================================================
# 11. The reader derives its indent step rather than assuming two spaces.
#
# MUTATION. Hard-coding `unit=2` in provision-siblings-from-lock.sh turns the
# four-space document into "could not read as a develop-list document", i.e.
# every consumer silently falls back the day `repro`'s formatter changes.
# Observed: "FAIL   with the same five siblings — did not contain [repro.lock
# pinned 5 siblings at exact commits]". Note the exit code stayed 0: `auto`
# fell back, which is exactly why the count and not the status is the assertion
# that catches this.
# ===========================================================================
new_ws
lock_with_siblings
run_provision auto "" "$LIST_INDENT4"
check "four-space pretty printing is read the same way" "$RC" "0"
contains "  with the same five siblings" "$OUT" "repro.lock pinned 5 siblings at exact commits"

# ===========================================================================
# 12. `siblings:` under the repro path: reconciled, never silently ignored.
#
# `auto` never reaches here with a declared list (section 7), so this is the
# forced-override contract. An entry the lock pins is redundant and dropped
# with both names in the message; an entry the lock does not name is handed
# back to clone-siblings as an ADDITIONAL set.
# ===========================================================================
new_ws
lock_with_siblings
run_provision repro-lock "isonim"$'\n'"codetracer-trace-format" "$LIST_OK"
check "a mixed declared list still provisions from the lock" "$RC" "0"
contains "  the locked entry is reported redundant, with its locked revision" "$OUT" \
	"'isonim' (from the 'siblings' input) is redundant under sibling-strategy: repro-lock — repro.lock pins isonim at e82b819d2d05efb6023a966e886fdbec6d1660cb"
contains "  and reported as dropped" "$OUT" "this entry is dropped"
contains "  the unlocked entry is reported as outside the lock" "$OUT" \
	"'codetracer-trace-format' (from the 'siblings' input) is NOT in repro.lock"
check "  and a follow-on clone is requested" "$(out_of late-clone)" "true"
check "  carrying only the entry the lock cannot supply" "$(block_of late-siblings)" \
	"codetracer-trace-format"
contains "  with the tally on the one-line report" "$OUT" \
	"1 declared entries dropped as redundant; 1 declared entries outside the lock handed to clone-siblings"

# `name=ref` on a repo the lock pins: the ref goes too, and is named. This is
# the exact shape that silently un-pinned four correctly-locked repos.
new_ws
lock_with_siblings
run_provision repro-lock "isonim=dev" "$LIST_OK"
contains "an entry's =ref is dropped with it, and the locked SHA is named" "$OUT" \
	"repro.lock pins isonim at e82b819d2d05efb6023a966e886fdbec6d1660cb"
check "  and nothing is handed to clone-siblings" "$(out_of late-clone)" "false"

# A declared list read from the file rather than the input.
new_ws
lock_with_siblings
printf 'nim-acp\nrepo-workspaces\n' >"$WS/.github/sibling-repos"
run_provision repro-lock "" "$LIST_OK"
contains "the file is reconciled the same way as the input" "$OUT" \
	"'repo-workspaces' (from .github/sibling-repos) is NOT in repro.lock"
check "  and only the uncovered entry is handed on" "$(block_of late-siblings)" "repo-workspaces"

# ===========================================================================
# 13. A failing `repro develop --all` is reported as what it is.
#
# Resolution already succeeded at this point — every sibling is pinned to an
# exact commit. Reporting a clone/adopt failure as a lock problem is how the
# original incident sent people to the wrong artefact for a week.
# ===========================================================================
new_ws
lock_with_siblings
run_provision auto "" "$LIST_OK" 0 1
check "a failing repro develop --all fails the step, on auto too" "$RC" "1"
contains "  and says it is not a resolution problem" "$OUT" "This is NOT a resolution problem"
contains "  naming the actual failure modes" "$OUT" "clone/adopt"

echo
echo "-----------------------------------------------------------------"
echo "sibling-strategy-step-test: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] || exit 1
exit 0
