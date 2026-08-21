#!/usr/bin/env bash
#
# longpaths-test.sh — contract suite for the Windows MAX_PATH half of
# `git-auth/authenticated-clone.sh`.
#
# THE DEFECT THIS GUARDS
# ----------------------
# Git for Windows refuses any path longer than 260 characters with
#
#     error: unable to create file <path>: Filename too long
#
# unless `core.longpaths` is true. `clone-siblings` clones `codetracer` — whose
# `.gitmodules` nests submodules that themselves recurse — next to a workspace
# that already starts at `C:\actions-runner\_work\<repo>\`, and the recursive
# `submodule update` in `authenticated-clone.sh` died exactly there, reported
# through that script's own `run_git` diagnostic:
#
#     ::error::submodule update failed for metacraft-labs/codetracer (git exit 1).
#     --- git output ---
#     error: unable to create file ...: Filename too long
#
# WHY THIS SUITE IS SHAPED LIKE THIS
# ----------------------------------
# The cheap test is to grep `authenticated-clone.sh` for the string
# `core.longpaths`. That passes for a fix installed in the wrong place, in the
# wrong order, or with the wrong value, and it is precisely the class of false
# pass this repo's other suites already refuse (see the header of
# ./authenticated-clone-test.sh).
#
# So the two things that actually have to be true are OBSERVED, with real git:
#
#   1. WHAT EACH `git` INVOCATION WAS HANDED. A shim on PATH records, per
#      invocation that `authenticated-clone.sh` makes, the value the numbered
#      git configuration in its environment resolves `core.longpaths` to, and
#      then execs the real git. That is what makes an ordering regression
#      visible: a fix installed AFTER the submodule update leaves the submodule
#      update's own record unset while every later record looks fine.
#
#   2. WHAT THE SUBMODULE PROCESSES ACTUALLY RESOLVED. `GIT_TRACE2_EVENT` plus
#      `GIT_TRACE2_CONFIG_PARAMS=core.longpaths` makes every git process in the
#      tree — the superproject's, and one per submodule at every depth — emit a
#      `def_param` event carrying the value IT resolved. A per-repo
#      `git -C <dest> config core.longpaths true` satisfies the superproject and
#      nothing below it, because a submodule is its own repository with its own
#      config file; the deep paths are in the submodules, so that fix would not
#      fix anything. The event stream tells the two apart.
#
# MUTATION-VERIFIED. Every detector is paired with a CONTROL run of plain git
# through the same shim and the same fixtures, and the suite asserts the
# detector goes quiet on it. An assertion nobody has seen fail is a comment.
#
# NO MOCKS OF GIT. Real git, real submodules, two levels of real nesting. The
# remotes are served over `file://` rather than HTTP because nothing here is
# about the transport or the credential — ./authenticated-clone-test.sh owns
# that — and `protocol.file.allow` has to be carried into the submodule
# processes for the fixture to work at all, which makes the fixture itself a
# second, independent witness that this environment channel propagates.
#
# Run: bash git-auth/longpaths-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE="$HERE/authenticated-clone.sh"
[[ -f $CLONE ]] || {
	echo "longpaths-test: cannot find $CLONE" >&2
	exit 2
}

REAL_GIT="$(command -v git)" || {
	echo "longpaths-test: git is not on PATH" >&2
	exit 2
}

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
at_least() { # <desc> <actual> <minimum>
	if [[ $2 -ge $3 ]]; then ok "$1 ($2 >= $3)"; else bad "$1" "expected at least $3, got $2"; fi
}

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Isolation.
#
# The developer running this suite may well have `core.longpaths` in their own
# `~/.gitconfig` (it is a reasonable thing to set), and the machine may have it
# in the system config. Either would make assertion (2) below pass without any
# fix at all. Both scopes are pointed at empty files, and the CONTROL run
# asserts the result: zero `def_param` events, i.e. no git process anywhere
# resolves `core.longpaths` unless this action put it there.
# ---------------------------------------------------------------------------
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
: >"$TMPROOT/gitconfig-global"
: >"$TMPROOT/gitconfig-system"
export GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig-global"
export GIT_CONFIG_SYSTEM="$TMPROOT/gitconfig-system"
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@local
export GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@local

git_q() { "$REAL_GIT" "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Fixtures: a superproject with a submodule that itself has a submodule.
#
# Two levels, not one, on purpose: one level is satisfied by any mechanism that
# reaches a direct child, and the org's real shape (codetracer ->
# codetracer-native-backend -> codetracer-rr) is deeper than that.
# ---------------------------------------------------------------------------
SRV="$TMPROOT/remotes/owner"
WORK="$TMPROOT/work"
mkdir -p "$SRV" "$WORK"

mk_repo() { # <name>
	local d="$WORK/$1"
	mkdir -p "$d"
	git_q init "$d"
	printf 'content of %s\n' "$1" >"$d/file.txt"
	git_q -C "$d" add -A
	git_q -C "$d" commit -m "init $1"
}

publish() { # <name>
	git_q clone --bare "$WORK/$1" "$SRV/$1.git"
	# `--rev` on a sibling clone names an exact commit, and a depth-1 fetch of a
	# commit that is not a branch tip needs the server to allow it.
	git_q -C "$SRV/$1.git" config uploadpack.allowAnySHA1InWant true
}

mk_repo leaf
publish leaf

mk_repo mid
git_q -C "$WORK/mid" -c protocol.file.allow=always \
	submodule add "file://$SRV/leaf.git" deep/leafmod
git_q -C "$WORK/mid" commit -m "add deep/leafmod"
publish mid

mk_repo super
git_q -C "$WORK/super" -c protocol.file.allow=always \
	submodule add "file://$SRV/mid.git" libs/midmod
git_q -C "$WORK/super" commit -m "add libs/midmod"
publish super

SUPER_SHA="$("$REAL_GIT" -C "$WORK/super" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# The shim. It records and then gets out of the way: it never changes what git
# is asked to do, and it execs the real binary by absolute path so it cannot
# recurse into itself.
# ---------------------------------------------------------------------------
SHIM="$TMPROOT/shim"
mkdir -p "$SHIM"
cat >"$SHIM/git" <<'SHIM_EOF'
#!/usr/bin/env bash
# Test shim (git-auth/longpaths-test.sh). Records what this invocation was
# handed, then execs the real git unchanged.
n=0
while [ -e "$LP_LOG_DIR/inv-$n.claimed" ]; do n=$((n + 1)); done
: >"$LP_LOG_DIR/inv-$n.claimed"

lp="<unset>"
pfa="<unset>"
c="${GIT_CONFIG_COUNT:-0}"
i=0
while [ "$i" -lt "$c" ]; do
	eval "k=\${GIT_CONFIG_KEY_$i-}"
	eval "v=\${GIT_CONFIG_VALUE_$i-}"
	case "$k" in
	core.longpaths) lp="$v" ;;
	protocol.file.allow) pfa="$v" ;;
	esac
	i=$((i + 1))
done

printf '%s\t%s\t%s\t%s\n' "$n" "$lp" "$pfa" "$*" >>"$LP_LOG_DIR/invocations"

export GIT_TRACE2_EVENT="$LP_LOG_DIR/trace-$n.json"
export GIT_TRACE2_CONFIG_PARAMS=core.longpaths
exec "$LP_REAL_GIT" "$@"
SHIM_EOF
chmod +x "$SHIM/git"
export LP_REAL_GIT="$REAL_GIT"

# `run_scenario <log-dir-name> <authenticated-clone args...>` -- run the real
# script with the shim first on PATH and a fresh log directory.
LP_LOG_DIR=""
run_scenario() {
	local name="$1"
	shift
	LP_LOG_DIR="$TMPROOT/logs/$name"
	mkdir -p "$LP_LOG_DIR"
	: >"$LP_LOG_DIR/invocations"
	export LP_LOG_DIR
	# The fixture's `file://` submodules are refused by git unless
	# `protocol.file.allow` says otherwise (CVE-2022-39253). It is installed as
	# PRE-EXISTING numbered configuration, at index 0, so the run also proves
	# the script APPENDS to an environment it did not create rather than
	# renumbering from zero and dropping it — `setup-nix` puts the job's
	# credential there by exactly this mechanism.
	env PATH="$SHIM:$PATH" \
		GIT_CONFIG_COUNT=1 \
		GIT_CONFIG_KEY_0=protocol.file.allow \
		GIT_CONFIG_VALUE_0=always \
		bash "$@"
}

# `field <n> <line>` -- tab-separated field, in pure bash.
lp_of() { # <invocations-file> <argv-substring> -> the core.longpaths column
	local file="$1" want="$2" n lp argv
	while IFS=$'\t' read -r n lp _ argv; do
		case "$argv" in
		*"$want"*)
			printf '%s' "$lp"
			return 0
			;;
		esac
	done <"$file"
	printf '<no-such-invocation>'
}

idx_of() { # <invocations-file> <argv-substring> -> the invocation index
	local file="$1" want="$2" n lp argv
	while IFS=$'\t' read -r n lp _ argv; do
		case "$argv" in
		*"$want"*)
			printf '%s' "$n"
			return 0
			;;
		esac
	done <"$file"
	printf -- '-1'
}

count_matching() { # <invocations-file> <argv-substring>
	local file="$1" want="$2" n lp argv c=0
	while IFS=$'\t' read -r n lp _ argv; do
		case "$argv" in
		*"$want"*) c=$((c + 1)) ;;
		esac
	done <"$file"
	printf '%s' "$c"
}

# ---------------------------------------------------------------------------
# Reading the trace2 event stream.
#
# Two event kinds are correlated by `sid` (trace2's per-process session id,
# whose value for a child is `<parent-sid>/<own-sid>`):
#
#   def_param  — this process resolved <param> to <value>. Emitted for every
#                process in the tree because `GIT_TRACE2_CONFIG_PARAMS` is
#                inherited.
#   def_repo   — this process opened a repository whose worktree is <path>. A
#                process may open more than one: `git submodule--helper` opens
#                the superproject AND, for bookkeeping, each submodule.
#
# THAT SECOND FACT IS WHY THE OBVIOUS ASSERTION IS NOT ENOUGH, and it was found
# by mutation rather than by reasoning. "Some process that touched the submodule
# worktree resolved core.longpaths=true" is ALSO satisfied by a per-repo
# `git -C <dest> config core.longpaths true`, because the helper that resolved
# it from the superproject's own config is one of the processes that opened the
# submodule. The mutation survived that assertion.
#
# So the question asked here is narrower and is the one that actually matters on
# Windows: did a git process whose ONLY repository was the submodule — one that
# never opened the superproject, and therefore could only have got the setting
# from the environment or from the submodule's own config — resolve it to true?
# Those are the processes that create the deep files.
#
# It is asked at BOTH levels of nesting, and the deeper one is the strict test.
# Measured against the per-repo mutation: at level 1 exactly one process still
# answers yes, and it is `git clone --separate-git-dir` for the submodule, which
# runs with its cwd still inside the SUPERPROJECT and so discovers and reads the
# superproject's config on the way past. At level 2 that accident is gone — the
# clone runs inside `libs/midmod`, whose config does not carry the key — and the
# assertion fails as it should. Both are kept: level 1 is still the natural
# thing to assert, and the pair records where its blind spot is.
# ---------------------------------------------------------------------------

sids_resolving_true() { # <trace>
	[[ -f $1 ]] || return 0
	grep -o '"sid":"[^"]*"[^}]*"param":"core\.longpaths","value":"true"' "$1" 2>/dev/null |
		sed 's/^"sid":"\([^"]*\)".*/\1/' | sort -u
}

sids_opening_worktree() { # <trace> <worktree>
	[[ -f $1 ]] || return 0
	grep -o '"sid":"[^"]*"[^}]*"worktree":"[^"]*"' "$1" 2>/dev/null |
		sed -n 's/^"sid":"\([^"]*\)".*"worktree":"\(.*\)"$/\1\t\2/p' |
		while IFS=$'\t' read -r _s _w; do
			[[ $_w == "$2" ]] && printf '%s\n' "$_s"
		done | sort -u
}

# `deep_resolvers <trace> <superproject-worktree> <submodule-worktree>` -- how
# many git processes opened ONLY the submodule and resolved core.longpaths=true.
deep_resolvers() {
	local trace="$1" root="$2" wt="$3"
	comm -12 \
		<(comm -23 <(sids_opening_worktree "$trace" "$wt") <(sids_opening_worktree "$trace" "$root")) \
		<(sids_resolving_true "$trace") | grep -c . || true
}

# `total_resolvers <trace>` -- distinct git processes resolving it to true, at
# any depth. Used for the control's "nobody resolves it at all" assertion.
total_resolvers() { sids_resolving_true "$1" | grep -c . || true; }

echo "=== scenario A: full clone with --submodules (the clone-repo shape) ==="

DEST_A="$TMPROOT/dest-a"
run_scenario a "$CLONE" --repo owner/super --dest "$DEST_A" \
	--submodules --url-base "file://$TMPROOT/remotes/"
RC_A=$?
LOG_A="$TMPROOT/logs/a/invocations"

check "authenticated-clone succeeded" "$RC_A" 0

# The clone actually happened, at both levels. Without this a fix that broke
# cloning outright would still satisfy every configuration assertion below.
[[ -f $DEST_A/file.txt ]] && ok "superproject is checked out" || bad "superproject is checked out"
[[ -f $DEST_A/libs/midmod/file.txt ]] && ok "level-1 submodule is checked out" ||
	bad "level-1 submodule is checked out"
[[ -f $DEST_A/libs/midmod/deep/leafmod/file.txt ]] && ok "level-2 submodule is checked out" ||
	bad "level-2 submodule is checked out"

# Non-vacuity: the log must have records in it, and enough of them to be the
# real thing rather than an empty scan reading as a clean one.
N_INV_A="$(count_matching "$LOG_A" "")"
at_least "the shim recorded the script's git invocations" "$N_INV_A" 2

# Every invocation, not just the interesting one.
BAD_A=0
UNSET_A=0
while IFS=$'\t' read -r _n _lp _pfa _argv; do
	[[ -z ${_n:-} ]] && continue
	if [[ $_lp != "true" ]]; then
		BAD_A=$((BAD_A + 1))
		[[ $_lp == "<unset>" ]] && UNSET_A=$((UNSET_A + 1))
		echo "     not carrying core.longpaths=true: [$_lp] git $_argv"
	fi
done <"$LOG_A"
check "every git invocation is handed core.longpaths=true" "$BAD_A" 0

# Named individually, because the two that matter fail differently: the clone
# is where a long path in the SUPERPROJECT lands, and the submodule update is
# where the reported failure actually happened. A fix installed after the
# submodule update leaves exactly this one record unset.
check "the recursive submodule update is handed core.longpaths=true" \
	"$(lp_of "$LOG_A" "submodule update")" "true"
check "the initial clone is handed core.longpaths=true" \
	"$(lp_of "$LOG_A" "clone --quiet")" "true"
check "exactly one recursive submodule update was run" \
	"$(count_matching "$LOG_A" "submodule update")" "1"

# Pre-existing numbered configuration survives: index 0 was the fixture's, and
# it has to still be in force at the invocation that needs it most.
check "pre-existing numbered config (protocol.file.allow) survives to the submodule update" \
	"$(
		while IFS=$'\t' read -r _n _lp _pfa _argv; do
			case "$_argv" in *"submodule update"*)
				printf '%s' "$_pfa"
				break
				;;
			esac
		done <"$LOG_A"
	)" "always"

# The property the whole fix rests on: the git processes that check the
# SUBMODULES out resolve it too, at both levels of nesting.
IDX_SUB_A="$(idx_of "$LOG_A" "submodule update")"
check "the submodule update invocation was traced" "$([[ $IDX_SUB_A -ge 0 ]] && echo yes || echo no)" "yes"
TRACE_A="$TMPROOT/logs/a/trace-$IDX_SUB_A.json"
[[ -s $TRACE_A ]] && ok "the submodule update produced a trace to read" ||
	bad "the submodule update produced a trace to read" "no events in $TRACE_A"
ROOT_A="$(cd "$DEST_A" && pwd -P)"
at_least "git processes resolving core.longpaths=true during the submodule update" \
	"$(total_resolvers "$TRACE_A")" 3
at_least "level-1 submodule-only git processes resolving core.longpaths=true" \
	"$(deep_resolvers "$TRACE_A" "$ROOT_A" "$ROOT_A/libs/midmod")" 1
at_least "level-2 submodule-only git processes resolving core.longpaths=true" \
	"$(deep_resolvers "$TRACE_A" "$ROOT_A" "$ROOT_A/libs/midmod/deep/leafmod")" 1

echo
echo "=== scenario B: shallow pinned clone (the \`clone-siblings\` shape) ==="

DEST_B="$TMPROOT/dest-b"
run_scenario b "$CLONE" --repo owner/super --dest "$DEST_B" \
	--rev "$SUPER_SHA" --shallow --submodules-optional \
	--url-base "file://$TMPROOT/remotes/"
RC_B=$?
LOG_B="$TMPROOT/logs/b/invocations"

check "authenticated-clone succeeded (shallow)" "$RC_B" 0

# `--submodules-optional` DOWNGRADES a failed submodule update to a warning and
# still exits 0, which is exactly how this defect stayed invisible for as long
# as it did. So the shallow scenario asserts the tree, not the exit code.
[[ -f $DEST_B/libs/midmod/deep/leafmod/file.txt ]] &&
	ok "level-2 submodule is checked out (shallow, optional)" ||
	bad "level-2 submodule is checked out (shallow, optional)"

N_INV_B="$(count_matching "$LOG_B" "")"
at_least "the shim recorded the shallow run's git invocations" "$N_INV_B" 4

BAD_B=0
while IFS=$'\t' read -r _n _lp _pfa _argv; do
	[[ -z ${_n:-} ]] && continue
	if [[ $_lp != "true" ]]; then
		BAD_B=$((BAD_B + 1))
		echo "     not carrying core.longpaths=true: [$_lp] git $_argv"
	fi
done <"$LOG_B"
check "every git invocation is handed core.longpaths=true (shallow)" "$BAD_B" 0

check "the depth-1 fetch of the pinned revision is handed core.longpaths=true" \
	"$(lp_of "$LOG_B" "fetch --quiet --depth 1")" "true"
check "the detached checkout is handed core.longpaths=true" \
	"$(lp_of "$LOG_B" "checkout --quiet --detach")" "true"

IDX_SUB_B="$(idx_of "$LOG_B" "submodule update")"
TRACE_B="$TMPROOT/logs/b/trace-$IDX_SUB_B.json"
[[ -s $TRACE_B ]] && ok "the shallow submodule update produced a trace to read" ||
	bad "the shallow submodule update produced a trace to read" "no events in $TRACE_B"
ROOT_B="$(cd "$DEST_B" && pwd -P)"
at_least "git processes resolving core.longpaths=true during the shallow submodule update" \
	"$(total_resolvers "$TRACE_B")" 3
at_least "level-1 submodule-only git processes resolving core.longpaths=true (shallow)" \
	"$(deep_resolvers "$TRACE_B" "$ROOT_B" "$ROOT_B/libs/midmod")" 1
at_least "level-2 submodule-only git processes resolving core.longpaths=true (shallow)" \
	"$(deep_resolvers "$TRACE_B" "$ROOT_B" "$ROOT_B/libs/midmod/deep/leafmod")" 1

echo
echo "=== control: the same fixtures WITHOUT authenticated-clone ==="
#
# Every detector above is now run against plain git doing the same work in the
# same environment. If any of them stays green here, it is not measuring the
# fix — it is measuring something that was already true (an inherited
# `~/.gitconfig`, a system config, a git build with a different default).

DEST_C="$TMPROOT/dest-c"
LP_LOG_DIR="$TMPROOT/logs/control"
mkdir -p "$LP_LOG_DIR"
: >"$LP_LOG_DIR/invocations"
export LP_LOG_DIR
env PATH="$SHIM:$PATH" \
	GIT_CONFIG_COUNT=1 \
	GIT_CONFIG_KEY_0=protocol.file.allow \
	GIT_CONFIG_VALUE_0=always \
	bash -c '
		set -e
		git clone --quiet "file://'"$TMPROOT"'/remotes/owner/super.git" "'"$DEST_C"'"
		git -C "'"$DEST_C"'" submodule update --init --recursive --quiet
	'
RC_C=$?
LOG_C="$TMPROOT/logs/control/invocations"

check "control run succeeded (so it is comparable)" "$RC_C" 0
[[ -f $DEST_C/libs/midmod/deep/leafmod/file.txt ]] &&
	ok "control checked out both submodule levels" ||
	bad "control checked out both submodule levels"

check "control: the submodule update is NOT handed core.longpaths" \
	"$(lp_of "$LOG_C" "submodule update")" "<unset>"
check "control: the clone is NOT handed core.longpaths" \
	"$(lp_of "$LOG_C" "clone --quiet")" "<unset>"

IDX_SUB_C="$(idx_of "$LOG_C" "submodule update")"
TRACE_C="$TMPROOT/logs/control/trace-$IDX_SUB_C.json"
[[ -s $TRACE_C ]] && ok "the control submodule update produced a trace to read" ||
	bad "the control submodule update produced a trace to read" "no events in $TRACE_C"
ROOT_C="$(cd "$DEST_C" && pwd -P)"
check "control: NO git process resolves core.longpaths at all" \
	"$(total_resolvers "$TRACE_C")" 0
# The worktree correlation itself must be working in the control, or the two
# `deep_resolvers` assertions above could be reading zero from a broken parse
# rather than from a missing setting.
at_least "control: the trace DOES record submodule worktrees (so the correlation is live)" \
	"$(sids_opening_worktree "$TRACE_C" "$ROOT_C/libs/midmod/deep/leafmod" | grep -c . || true)" 1
check "control: level-2 submodule-only git processes resolving core.longpaths=true" \
	"$(deep_resolvers "$TRACE_C" "$ROOT_C" "$ROOT_C/libs/midmod/deep/leafmod")" 0

echo
echo "-- $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
