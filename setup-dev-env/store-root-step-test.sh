#!/usr/bin/env bash
#
# store-root-step-test.sh — contract suite for decide-store-root.sh.
#
# WHAT IS BEING GUARDED
# ---------------------
# Self-hosted Linux runners mount a shared, persistent reprobuild CAS into every
# per-job container. Reprobuild uses it only if `REPRO_STORE_ROOT` points at it,
# nothing set that variable, and so the shared store stayed empty from the day it
# was created while every job built into a container-local directory that was
# destroyed with the container. `decide-store-root.sh` closes that gap.
#
# The interesting half is not the export. It is that the SAME action runs on
# GitHub-hosted runners, on macOS and on Windows, where the mount does not
# exist — and exporting a store root there would be worse than the gap it fixes.
# So the suite covers all three shapes the runner fleet actually presents:
#
#   1. mount present and writable    -> exported
#   2. mount absent                  -> not exported, and the job does NOT fail
#   3. mount present, not writable   -> not exported, and the job does NOT fail
#
# plus the shapes that turn a passing implementation into a wrong one:
#
#   4. present, `-w` says yes, a real write fails (the quota-exhausted store —
#      the mount is bounded by a refquota, so this is where it ends up, not a
#      hypothetical)
#   5. a caller that set `REPRO_STORE_ROOT` itself keeps its value
#   6. the probe leaves nothing behind in the store
#   7. every path prints its decision and exits 0
#
# NEGATIVE CONTROLS
# -----------------
# Each of cases 1-5 is paired with a MUTANT of the shipped script — the real
# file with one guard removed — and the suite requires the case to FAIL against
# the mutant. A case that passes against both the real script and a script with
# its guard deleted is not testing anything, and this is a campaign that has
# already found seven such controls.
#
# The mutants are derived from the shipped file at run time by exact-line
# replacement, and `mutate` ABORTS if a line it was told to replace is not
# there. A control that silently stopped mutating would be the same defect one
# level up.
#
# Needs no network. Must NOT be run as root: cases 3 and 5 rely on `chmod` being
# able to make a directory unwritable, which is not true for uid 0, and a suite
# that quietly passed as root would be case 7 of the seven.
#
# Run:  bash setup-dev-env/store-root-step-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/decide-store-root.sh"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

failures=0
skips=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
	printf 'FAIL %s\n' "$1"
	shift
	[ "$#" -gt 0 ] && printf '     %s\n' "$@"
	failures=$((failures + 1))
}
skip() {
	printf 'SKIP %s\n' "$1"
	shift
	[ "$#" -gt 0 ] && printf '     %s\n' "$@"
	skips=$((skips + 1))
}

if [ ! -f "$SCRIPT" ]; then
	echo "store-root-step-test: $SCRIPT not found" >&2
	exit 2
fi

if [ "$(id -u)" -eq 0 ]; then
	echo "store-root-step-test: refusing to run as root." >&2
	echo "  Cases 3 and 5 make a directory unwritable with chmod and assert the" >&2
	echo "  script declines it. uid 0 bypasses those bits, so as root both cases" >&2
	echo "  would pass no matter what the script did. Run unprivileged." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# mutate <outfile> <from-line> <to-line> [<from-line> <to-line> ...]
#
# Copies the shipped script, replacing each exact <from-line> with <to-line>.
# Every <from-line> must match at least once, or the mutant is not a mutant and
# the negative control built on it proves nothing.
# ---------------------------------------------------------------------------
mutate() {
	local out="$1"
	shift
	local -a from=() to=() hit=()
	while [ "$#" -gt 0 ]; do
		from+=("$1")
		to+=("$2")
		hit+=(0)
		shift 2
	done

	: >"$out"
	local line i n
	n=${#from[@]}
	while IFS= read -r line || [ -n "$line" ]; do
		i=0
		while [ "$i" -lt "$n" ]; do
			if [ "$line" = "${from[$i]}" ]; then
				line="${to[$i]}"
				hit[$i]=1
				break
			fi
			i=$((i + 1))
		done
		printf '%s\n' "$line" >>"$out"
	done <"$SCRIPT"

	i=0
	while [ "$i" -lt "$n" ]; do
		if [ "${hit[$i]}" -eq 0 ]; then
			echo "store-root-step-test: mutation target not found in $SCRIPT:" >&2
			echo "    ${from[$i]}" >&2
			echo "  The negative control derived from it would be vacuous, so the" >&2
			echo "  suite fails rather than reporting a pass it cannot justify." >&2
			exit 2
		fi
		i=$((i + 1))
	done

	if cmp -s "$SCRIPT" "$out"; then
		echo "store-root-step-test: mutant $out is identical to the original" >&2
		exit 2
	fi
}

# The exact guards, quoted from the shipped file. `mutate` fails loudly if any
# of these stops matching, so an edit to the script cannot silently defuse a
# control here.
G_PRESENT='elif [ ! -d "${CANDIDATE}" ]; then'
G_WRITABLE='elif [ ! -w "${CANDIDATE}" ]; then'
G_PROBE='  if (: >"${_probe}") 2>/dev/null; then'
G_CALLER='if [ -n "${REPRO_STORE_ROOT:-}" ]; then'
G_EXPORT="    printf 'REPRO_STORE_ROOT=%s\\n' \"\${CANDIDATE}\" >>\"\${GITHUB_ENV}\""

# ---------------------------------------------------------------------------
# run <script> <candidate-path> [<preset-store-root>]
#
# Executes one invocation in a fresh env-file sandbox. Sets RUN_ENV/RUN_OUT to
# the files the script wrote, RUN_RC to its exit status and RUN_LOG to stdout+
# stderr.
# ---------------------------------------------------------------------------
run_seq=0
run() {
	local script="$1" candidate="$2" preset="${3-}"
	run_seq=$((run_seq + 1))
	RUN_ENV="$TMP/env.$run_seq"
	RUN_OUT="$TMP/out.$run_seq"
	: >"$RUN_ENV"
	: >"$RUN_OUT"
	if [ -n "$preset" ]; then
		RUN_LOG="$(SHARED_STORE_PATH="$candidate" REPRO_STORE_ROOT="$preset" \
			GITHUB_ENV="$RUN_ENV" GITHUB_OUTPUT="$RUN_OUT" \
			bash "$script" 2>&1)"
	else
		RUN_LOG="$(env -u REPRO_STORE_ROOT SHARED_STORE_PATH="$candidate" \
			GITHUB_ENV="$RUN_ENV" GITHUB_OUTPUT="$RUN_OUT" \
			bash "$script" 2>&1)"
	fi
	RUN_RC=$?
}

exported() { # was REPRO_STORE_ROOT written to the env file?
	grep -q '^REPRO_STORE_ROOT=' "$RUN_ENV" 2>/dev/null
}
exported_value() { sed -n 's/^REPRO_STORE_ROOT=//p' "$RUN_ENV" 2>/dev/null; }
decision() { sed -n 's/^decision=//p' "$RUN_OUT" 2>/dev/null; }

# ============================================================== case 1 ======
# Mount present and writable: export it.
store="$TMP/store-ok"
mkdir -p "$store"
run "$SCRIPT" "$store"

if [ "$RUN_RC" -eq 0 ]; then
	pass "case 1: present+writable exits 0"
else
	fail "case 1: present+writable must exit 0 (got $RUN_RC)" "$RUN_LOG"
fi
if exported && [ "$(exported_value)" = "$store" ]; then
	pass "case 1: exports REPRO_STORE_ROOT to \$GITHUB_ENV"
else
	fail "case 1: must export the mount path" "env file: $(cat "$RUN_ENV")" "$RUN_LOG"
fi
if [ "$(decision)" = "shared" ]; then
	pass "case 1: reports decision=shared"
else
	fail "case 1: decision was '$(decision)', expected 'shared'" "$RUN_LOG"
fi
case "$RUN_LOG" in
*"reprobuild store = shared at $store"*) pass "case 1: says which store was chosen" ;;
*) fail "case 1: did not name the chosen store" "$RUN_LOG" ;;
esac

# case 6: the writability probe leaves nothing behind. A stray file at the root
# of a content-addressed store is not fatal, but a probe that accumulated one
# per job would be this fix's own litter.
leftovers="$(find "$store" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
if [ "$leftovers" = "0" ]; then
	pass "case 6: the probe leaves the store empty"
else
	fail "case 6: probe left $leftovers entries behind" "$(find "$store" -mindepth 1)"
fi

# -- negative control 1: a script that never exports must fail case 1 --------
mutate "$TMP/mut-never" "$G_EXPORT" "    :"
run "$TMP/mut-never" "$store"
if exported; then
	fail "control 1 is vacuous: the never-export mutant still exported"
else
	pass "control 1: case 1 fails against a mutant that never exports"
fi

# ============================================================== case 2 ======
# Mount absent — GitHub-hosted runners, macOS, Windows. Do not export, do not
# fail. This is the case that makes the fix safe to ship to every repo.
absent="$TMP/no-such-store"
run "$SCRIPT" "$absent"

if [ "$RUN_RC" -eq 0 ]; then
	pass "case 2: absent mount exits 0 (does not fail the job)"
else
	fail "case 2: an absent mount must not fail the job (got $RUN_RC)" "$RUN_LOG"
fi
if exported; then
	fail "case 2: must NOT export a store root that does not exist" "env file: $(cat "$RUN_ENV")"
else
	pass "case 2: absent mount exports nothing"
fi
if [ "$(decision)" = "absent" ]; then
	pass "case 2: reports decision=absent"
else
	fail "case 2: decision was '$(decision)', expected 'absent'" "$RUN_LOG"
fi
if [ ! -e "$absent" ]; then
	pass "case 2: does not create the missing mount point"
else
	fail "case 2: created $absent, which is the failure mode it exists to avoid"
fi

# -- negative control 2: the naive fix (export unconditionally) --------------
# This is the implementation the ticket would have got without the mount test,
# and it is the one that breaks every macOS and Windows job.
mutate "$TMP/mut-unconditional" \
	"$G_PRESENT" "elif false; then" \
	"$G_WRITABLE" "elif false; then" \
	"$G_PROBE" "  if true; then"
run "$TMP/mut-unconditional" "$absent"
if exported; then
	pass "control 2: case 2 fails against an unconditional-export mutant"
else
	fail "control 2 is vacuous: the unconditional mutant did not export"
fi

# ============================================================== case 3 ======
# Mount present but not writable by this job.
noperm="$TMP/store-noperm"
mkdir -p "$noperm"
chmod 555 "$noperm"
run "$SCRIPT" "$noperm"

if [ "$RUN_RC" -eq 0 ]; then
	pass "case 3: unwritable mount exits 0 (does not fail the job)"
else
	fail "case 3: an unwritable mount must not fail the job (got $RUN_RC)" "$RUN_LOG"
fi
if exported; then
	fail "case 3: must NOT export a store root it cannot write" "env file: $(cat "$RUN_ENV")"
else
	pass "case 3: unwritable mount exports nothing"
fi
if [ "$(decision)" = "not-writable" ]; then
	pass "case 3: reports decision=not-writable"
else
	fail "case 3: decision was '$(decision)', expected 'not-writable'" "$RUN_LOG"
fi

# -- negative control 3: presence-only (the plausible half-fix) --------------
mutate "$TMP/mut-presence-only" \
	"$G_WRITABLE" "elif false; then" \
	"$G_PROBE" "  if true; then"
run "$TMP/mut-presence-only" "$noperm"
if exported; then
	pass "control 3: case 3 fails against a presence-only mutant"
else
	fail "control 3 is vacuous: the presence-only mutant did not export"
fi
chmod 755 "$noperm"

# ============================================================== case 4 ======
# `-w` says writable and a real write still fails. This is what a store that
# has reached its quota looks like, so it is the shape the fleet will actually
# hit, not a contrived one. Constructed as an inode-exhausted tmpfs inside a
# user namespace so the suite needs no privileges.
if unshare --map-root-user --mount true 2>/dev/null; then
	probe_env="$TMP/env.probe"
	probe_out="$TMP/out.probe"
	: >"$probe_env"
	: >"$probe_out"
	mkdir -p "$TMP/store-full"
	probe_log="$(unshare --map-root-user --mount bash -c '
		set -u
		mount -t tmpfs -o size=64k,nr_inodes=2,mode=1777 tmpfs "$1/store-full" || exit 90
		# Consume the one spare inode so the next create returns ENOSPC while
		# the directory still reports as writable.
		: > "$1/store-full/filler" || exit 91
		[ -w "$1/store-full" ] || exit 92
		env -u REPRO_STORE_ROOT \
			SHARED_STORE_PATH="$1/store-full" \
			GITHUB_ENV="$2" GITHUB_OUTPUT="$3" \
			bash "$4" 2>&1
	' _ "$TMP" "$probe_env" "$probe_out" "$SCRIPT" 2>&1)"
	probe_rc=$?

	case "$probe_rc" in
	90 | 91 | 92)
		skip "case 4: could not build the quota-exhausted fixture (helper exit $probe_rc)" "$probe_log"
		;;
	*)
		if [ "$probe_rc" -eq 0 ]; then
			pass "case 4: a failing write on a '-w'-writable store exits 0"
		else
			fail "case 4: must not fail the job (got $probe_rc)" "$probe_log"
		fi
		if grep -q '^REPRO_STORE_ROOT=' "$probe_env"; then
			fail "case 4: must NOT export a store it cannot actually write to" "$(cat "$probe_env")"
		else
			pass "case 4: exports nothing when the real write fails"
		fi
		if [ "$(sed -n 's/^decision=//p' "$probe_out")" = "probe-failed" ]; then
			pass "case 4: reports decision=probe-failed"
		else
			fail "case 4: decision was '$(sed -n 's/^decision=//p' "$probe_out")'" "$probe_log"
		fi

		# -- negative control 4: trust `-w` and skip the write ---------------
		mutate "$TMP/mut-trust-w" "$G_PROBE" "  if true; then"
		ctl_env="$TMP/env.probe-ctl"
		: >"$ctl_env"
		unshare --map-root-user --mount bash -c '
			set -u
			mount -t tmpfs -o size=64k,nr_inodes=2,mode=1777 tmpfs "$1/store-full" || exit 90
			: > "$1/store-full/filler" || exit 91
			env -u REPRO_STORE_ROOT \
				SHARED_STORE_PATH="$1/store-full" \
				GITHUB_ENV="$2" GITHUB_OUTPUT="/dev/null" \
				bash "$3" >/dev/null 2>&1
		' _ "$TMP" "$ctl_env" "$TMP/mut-trust-w" >/dev/null 2>&1
		if grep -q '^REPRO_STORE_ROOT=' "$ctl_env"; then
			pass "control 4: case 4 fails against a mutant that trusts -w"
		else
			fail "control 4 is vacuous: the trust--w mutant did not export"
		fi
		;;
	esac
else
	skip "case 4: unprivileged user namespaces unavailable; the '-w says yes, write fails' fixture cannot be built here" \
		"Run this suite where 'unshare --map-root-user --mount' works to cover the quota-exhausted store."
fi

# ============================================================== case 8 ======
# An already-initialised store whose index this job cannot open read-write. The
# root of the shared mount is world-writable by construction, so the root probe
# passes; every store operation still opens `index.db`, which belongs to
# whichever job reached the mount first. Today's runners all map guest root to
# one host uid so this cannot bite, but nothing pins that, and the failure it
# would produce is the late confusing one inside a build.
initialised="$TMP/store-initialised"
mkdir -p "$initialised"
: >"$initialised/index.db"
chmod 444 "$initialised/index.db"
run "$SCRIPT" "$initialised"

if [ "$RUN_RC" -eq 0 ]; then
	pass "case 8: an unwritable index.db exits 0 (does not fail the job)"
else
	fail "case 8: must not fail the job (got $RUN_RC)" "$RUN_LOG"
fi
if exported; then
	fail "case 8: must NOT export a store whose index it cannot write" "$(cat "$RUN_ENV")"
else
	pass "case 8: exports nothing when index.db is unwritable"
fi
if [ "$(decision)" = "not-writable" ]; then
	pass "case 8: reports decision=not-writable"
else
	fail "case 8: decision was '$(decision)', expected 'not-writable'" "$RUN_LOG"
fi

# A WRITABLE index.db must still be exported, or the check above is just a way
# of switching the shared store off once it has been used once.
chmod 644 "$initialised/index.db"
run "$SCRIPT" "$initialised"
if exported && [ "$(decision)" = "shared" ]; then
	pass "case 8: a writable index.db is still exported"
else
	fail "case 8: an initialised, writable store must be used" "$RUN_LOG"
fi
chmod 444 "$initialised/index.db"

# -- negative control 8: skip the index check -------------------------------
mutate "$TMP/mut-no-index-check" \
	'    if [ -e "${CANDIDATE}/index.db" ] && [ ! -w "${CANDIDATE}/index.db" ]; then' \
	"    if false; then"
run "$TMP/mut-no-index-check" "$initialised"
if exported; then
	pass "control 8: case 8 fails against a mutant that skips the index check"
else
	fail "control 8 is vacuous: the no-index-check mutant did not export"
fi
chmod 644 "$initialised/index.db"

# ============================================================== case 5 ======
# A caller that set REPRO_STORE_ROOT itself keeps it, even when a usable mount
# is right there. Deliberate configuration outranks an available mount.
run "$SCRIPT" "$store" "$TMP/callers-own-store"
if exported; then
	fail "case 5: must not rewrite a caller's own REPRO_STORE_ROOT" "$(cat "$RUN_ENV")"
else
	pass "case 5: a caller's own REPRO_STORE_ROOT is left alone"
fi
if [ "$(decision)" = "caller" ]; then
	pass "case 5: reports decision=caller"
else
	fail "case 5: decision was '$(decision)', expected 'caller'" "$RUN_LOG"
fi

# -- negative control 5: clobber the caller ---------------------------------
mutate "$TMP/mut-clobber" "$G_CALLER" "if false; then"
run "$TMP/mut-clobber" "$store" "$TMP/callers-own-store"
if exported; then
	pass "control 5: case 5 fails against a mutant that clobbers the caller"
else
	fail "control 5 is vacuous: the clobbering mutant did not export"
fi

# ============================================================== case 7 ======
# An empty shared-store-path switches the probe off entirely, and every path
# still prints a decision. A silent path is the bug this whole script is a fix
# for: the shared store sat empty because nothing ever said which store a job
# was using.
run "$SCRIPT" ""
if [ "$RUN_RC" -eq 0 ] && ! exported && [ "$(decision)" = "disabled" ]; then
	pass "case 7: an empty shared-store-path disables the probe cleanly"
else
	fail "case 7: empty shared-store-path (rc=$RUN_RC decision='$(decision)')" "$RUN_LOG"
fi

for c in "$store" "$absent" "$noperm" ""; do
	run "$SCRIPT" "$c"
	case "$RUN_LOG" in
	*"setup-dev-env: reprobuild store = "*) ;;
	*)
		fail "case 7: no decision line printed for candidate '${c:-<empty>}'" "$RUN_LOG"
		continue
		;;
	esac
	if [ "$RUN_RC" -ne 0 ]; then
		fail "case 7: candidate '${c:-<empty>}' exited $RUN_RC"
	fi
done
pass "case 7: every path prints its decision and exits 0"

# ---------------------------------------------------------------------------
echo
if [ "$skips" -gt 0 ]; then
	echo "store-root-step-test: ${skips} case(s) skipped (reported above, not counted as passes)."
fi
if [ "$failures" -eq 0 ]; then
	echo "store-root-step-test: all cases passed."
	exit 0
fi
echo "store-root-step-test: ${failures} case(s) failed."
exit 1
