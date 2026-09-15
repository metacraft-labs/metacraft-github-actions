#!/usr/bin/env bash
#
# nix-netrc-test.sh — contract suite for write-nix-netrc.sh and for the part of
# setup-nix/action.yml that hands it the tokens.
#
# WHAT IS BEING GUARDED
# ---------------------
# `setup-nix` tells nix to use the caller's private Attic cache
# (`substituters = https://cache.nixos.org $EXTRA_SUBSTITUTERS`) and tells it
# where the credentials are (`netrc-file = …/netrc`). Until this change the
# netrc had one entry, `machine github.com`, and nothing anywhere gave nix a
# credential for that cache: `GET <cache>/nix-cache-info` answered 401, nix
# disabled the substituter and retried, and every path not on cache.nixos.org
# was built from source. The cost is invisible on a warm bare-metal runner and
# total on an ephemeral one.
#
# So the contracts below are about two opposite failure directions, the same
# pair configure-git-auth-test.sh is organised around:
#
#   TOO NARROW  — the cache credential is absent, or is filed under a `machine`
#                 name curl does not match (a port, a path, brackets). All four
#                 are the SAME observable as the defect being fixed: silent
#                 anonymous reads, 401, source builds.
#   TOO BROAD   — a token reaches a host that did not issue it, or the file
#                 grows an entry when no token was supplied at all (which would
#                 make this change observable in CI before the workflows that
#                 pass `attic-token` land, and this suite pins that it does not).
#
# NO MOCKS AND NO RE-IMPLEMENTATION. Every wire assertion runs the real
# `write-nix-netrc.sh`, then runs the real `curl` — the client nix hands this
# file to, via CURLOPT_NETRC_FILE — against a real HTTP origin that journals
# the credential each request arrived with (./netrc-probe-server.py). Nothing
# here re-implements netrc matching, because a re-implementation would agree
# with itself while disagreeing with curl. That is not hypothetical for this
# file: a `machine` token carrying a port or a path is perfectly well-formed
# netrc and matches NOTHING, so a suite that only greps the file reports a
# green tick for the exact bug it was written to prevent.
#
# `--resolve <host>:<port>:127.0.0.1` is what lets the request URL carry a real
# hostname — `cache.example.com`, `github.com` — while the connection lands on
# the local probe. curl matches `machine` against the hostname it parsed from
# the URL, so the matching under test is the real one.
#
# NEGATIVE CONTROLS. The wire cases are paired with MUTANTS of the shipped
# script — the real file with one guard removed — and each pair fails the suite
# if the case passes against its mutant. `mutate` aborts when a line it was
# told to replace is not present, so a control cannot silently stop mutating.
#
# Needs python3 (for the probe origin) and curl. Both are present on the stock
# `ubuntu-latest` runner this repo's suites run on; git-auth's suite already
# depends on the same two. Their absence is a hard error, never a skip.
#
# Run:  bash setup-nix/nix-netrc-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/write-nix-netrc.sh"
SERVER="$HERE/netrc-probe-server.py"
ACTION_YML="$HERE/action.yml"

for f in "$SCRIPT" "$SERVER"; do
	[ -f "$f" ] || {
		echo "nix-netrc-test: cannot find $f" >&2
		exit 2
	}
done
for c in python3 curl; do
	command -v "$c" >/dev/null 2>&1 || {
		echo "nix-netrc-test: '$c' is required and not on PATH." >&2
		echo "  The wire assertions are the point of this suite; skipping them would" >&2
		echo "  leave only file-content greps, which pass for a credential filed under" >&2
		echo "  a machine name curl never matches. Install it rather than skipping." >&2
		exit 2
	}
done

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL $1"
	[ -n "${2:-}" ] && echo "     $2"
	return 0
}
check() { # <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

TMPROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Fixture credentials, shaped so a substring search for one cannot accidentally
# match the other or any ordinary text.
GH_TOK="ghs_nixnetrcSUITEgithubTOKEN000000000000"
ATTIC_TOK="eyJhbGciOiJIUzI1NiJ9.nixnetrcSUITEatticTOKEN.sig000"
ATTIC_HOST="cache.example.com"
ATTIC_ENDPOINT_DEFAULT="https://${ATTIC_HOST}/"

# ---------------------------------------------------------------------------
# mutate <outfile> <from-line> <to-line> [<from-line> <to-line> ...]
#
# The shipped script with exact lines replaced. Every <from-line> must match at
# least once, or the "mutant" is the original and the control proves nothing.
# ---------------------------------------------------------------------------
mutate() { # <out> <from> <to> ...
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
			echo "nix-netrc-test: mutate found no line matching:" >&2
			echo "    ${from[$i]}" >&2
			echo "  The negative control built on this mutant would be testing the" >&2
			echo "  unmodified script against itself. Fix the mutation, not the test." >&2
			exit 2
		fi
		i=$((i + 1))
	done
}

# run_writer <script> <netrc-path> [KEY=VALUE ...] -> RC, OUT
#
# Runs a writer with a controlled environment. `env -i` so nothing inherited
# from this shell (a real ATTIC_TOKEN, a real HOME) can decide a case.
run_writer() { # <script> <netrc> [env assignments...]
	local script="$1" netrc="$2"
	shift 2
	RC=0
	OUT="$(env -i \
		PATH="$PATH" \
		HOME="$TMPROOT/home" \
		NETRC_PATH="$netrc" \
		"$@" \
		bash "$script" 2>&1)" || RC=$?
	return 0
}

mkdir -p "$TMPROOT/home"

# ---------------------------------------------------------------------------
# The probe origin.
# ---------------------------------------------------------------------------
JOURNAL="$TMPROOT/journal"
python3 "$SERVER" --journal "$JOURNAL" >"$TMPROOT/port" 2>"$TMPROOT/server.err" &
SERVER_PID=$!
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	PORT="$(cat "$TMPROOT/port" 2>/dev/null)"
	[ -n "$PORT" ] && break
	sleep 0.25
done
if [ -z "$PORT" ]; then
	echo "nix-netrc-test: probe server did not start" >&2
	cat "$TMPROOT/server.err" >&2
	exit 2
fi

# probe <netrc> <host> <path> -> CODE, CRED_USER, CRED_PASS
#
# One authenticated-or-not GET at <host>, journalled by the origin. The journal
# is truncated first so each case reads only its own request.
probe() { # <netrc> <host> <path>
	local netrc="$1" host="$2" path="$3" line
	: >"$JOURNAL"
	CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
		--netrc-file "$netrc" \
		--resolve "${host}:${PORT}:127.0.0.1" \
		"http://${host}:${PORT}${path}" 2>/dev/null)" || CODE="curl-failed"
	# The LAST journalled request: a 401 challenge makes curl retry, and the
	# retry is the one carrying the credential.
	line="$(tail -n 1 "$JOURNAL" 2>/dev/null)"
	if [ -z "$line" ]; then
		CRED_USER="<no-request>"
		CRED_PASS="<no-request>"
		return 0
	fi
	CRED_USER="$(printf '%s' "$line" | cut -f2)"
	CRED_PASS="$(printf '%s' "$line" | cut -f3)"
	return 0
}

echo "== 1. no attic-token: the file is exactly what this action wrote before =="

# The pre-change implementation, reproduced verbatim from the `run:` body this
# change replaced. Byte identity against it is the proof that landing the read
# credential ahead of the workflows that supply a token changes NOTHING in CI.
LEGACY="$TMPROOT/legacy-netrc"
printf 'machine github.com login x-access-token password %s\n' "$GH_TOK" >"$LEGACY"

N1="$TMPROOT/netrc-1"
run_writer "$SCRIPT" "$N1" GH_TOKEN="$GH_TOK"
check "writes with no attic-token and exits 0" "$RC" "0"
check "the file is byte-identical to the pre-change netrc" \
	"$(sha256sum <"$N1" | cut -d' ' -f1)" "$(sha256sum <"$LEGACY" | cut -d' ' -f1)"
check "exactly one entry" "$(grep -c '^machine ' "$N1")" "1"
check "the attic token appears nowhere" "$(grep -c "$ATTIC_TOK" "$N1")" "0"

# Same, with an endpoint present but no token — the shape EVERY caller in this
# org has today, since `attic-endpoint` carries a default.
N1B="$TMPROOT/netrc-1b"
run_writer "$SCRIPT" "$N1B" GH_TOKEN="$GH_TOK" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "an endpoint without a token adds nothing" \
	"$(sha256sum <"$N1B" | cut -d' ' -f1)" "$(sha256sum <"$LEGACY" | cut -d' ' -f1)"

# ... and with substituters declared too, which is the LRC edges' exact shape.
N1C="$TMPROOT/netrc-1c"
run_writer "$SCRIPT" "$N1C" GH_TOKEN="$GH_TOK" \
	ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT" \
	EXTRA_SUBSTITUTERS="https://${ATTIC_HOST}/codetracer"
check "a declared substituter without a token still adds nothing" \
	"$(sha256sum <"$N1C" | cut -d' ' -f1)" "$(sha256sum <"$LEGACY" | cut -d' ' -f1)"
case "$OUT" in
*"read them ANONYMOUSLY"*) ok "the anonymous-read condition is named in the log" ;;
*) bad "the anonymous-read condition is named in the log" "output was: $OUT" ;;
esac

# NEGATIVE CONTROL for the three cases above: a writer that appends the attic
# entry unconditionally. If byte-identity still held, it would be holding for
# some reason other than the guard.
M_ALWAYS="$TMPROOT/mutant-always.sh"
mutate "$M_ALWAYS" 'if [ -n "$ATTIC_TOKEN" ]; then' 'if true; then'
NM="$TMPROOT/netrc-mutant-always"
run_writer "$M_ALWAYS" "$NM" GH_TOKEN="$GH_TOK" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
if [ "$(sha256sum <"$NM" 2>/dev/null | cut -d' ' -f1)" = "$(sha256sum <"$LEGACY" | cut -d' ' -f1)" ]; then
	bad "CONTROL: a writer that always appends is caught by the byte-identity case" \
		"the mutant produced the same bytes, so that case proves nothing"
else
	ok "CONTROL: a writer that always appends is caught by the byte-identity case"
fi

echo
echo "== 2. attic-token supplied: nix can READ the private cache =="

N2="$TMPROOT/netrc-2"
run_writer "$SCRIPT" "$N2" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "writes with an attic-token and exits 0" "$RC" "0"
check "two entries" "$(grep -c '^machine ' "$N2")" "2"
check "the attic entry names the bare host" \
	"$(grep -c "^machine ${ATTIC_HOST} password " "$N2")" "1"

# THE WIRE. This is the assertion the whole suite exists for.
probe "$N2" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache receives the attic token" "$CRED_PASS" "$ATTIC_TOK"
check "the cache request is authorised" "$CODE" "200"

probe "$N2" "github.com" "/metacraft-labs/codetracer"
check "github.com still receives the github token" "$CRED_PASS" "$GH_TOK"
check "github.com still receives the x-access-token login" "$CRED_USER" "x-access-token"

# TOO BROAD, both directions, observed rather than reasoned about.
probe "$N2" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache never receives the github token" \
	"$(test "$CRED_PASS" = "$GH_TOK" && echo leaked || echo no)" "no"
probe "$N2" "github.com" "/metacraft-labs/codetracer"
check "github.com never receives the attic token" \
	"$(test "$CRED_PASS" = "$ATTIC_TOK" && echo leaked || echo no)" "no"
probe "$N2" "third-party.example.org" "/whatever"
check "a host with no entry receives no credential at all" "$CRED_PASS" "-"

# NEGATIVE CONTROL for the wire case: the shipped script with the attic entry
# never appended — i.e. the defect as it shipped.
M_NONE="$TMPROOT/mutant-none.sh"
mutate "$M_NONE" 'if [ -n "$ATTIC_TOKEN" ]; then' 'if false; then'
NMN="$TMPROOT/netrc-mutant-none"
run_writer "$M_NONE" "$NMN" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
probe "$NMN" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "CONTROL: without the entry the cache gets nothing and answers 401" "$CODE" "401"
check "CONTROL: without the entry no credential reaches the cache" "$CRED_PASS" "-"

echo
echo "== 3. the machine name is the HOST, which is the only thing curl matches =="

# Each of these endpoints must produce the same working entry. A port, a path
# or a trailing slash in a `machine` token is valid netrc that matches nothing.
for ep in \
	"https://${ATTIC_HOST}" \
	"https://${ATTIC_HOST}/" \
	"https://${ATTIC_HOST}/codetracer" \
	"https://${ATTIC_HOST}:8443/codetracer" \
	"https://user:pw@${ATTIC_HOST}/codetracer"; do
	NE="$TMPROOT/netrc-ep"
	run_writer "$SCRIPT" "$NE" GH_TOKEN="$GH_TOK" \
		ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="$ep"
	if [ "$RC" -ne 0 ]; then
		bad "endpoint '$ep' yields a usable entry" "writer exited $RC: $OUT"
		continue
	fi
	probe "$NE" "$ATTIC_HOST" "/codetracer/nix-cache-info"
	check "endpoint '$ep' -> the token reaches ${ATTIC_HOST}" "$CRED_PASS" "$ATTIC_TOK"
done

# NEGATIVE CONTROL: keep the path in the machine name (and disable the guard
# that would otherwise refuse the resulting name, so the mutant produces a
# plausible-looking file rather than an error). curl must then send nothing.
M_PATH="$TMPROOT/mutant-path.sh"
mutate "$M_PATH" \
	'	authority="${authority%%/*}" # path' '	: # mutant: path not stripped' \
	'	*[!0-9A-Za-z._-]*)' '	*XXXneverXXX*)'
NMP="$TMPROOT/netrc-mutant-path"
run_writer "$M_PATH" "$NMP" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="https://${ATTIC_HOST}/codetracer"
if [ "$RC" -ne 0 ]; then
	bad "CONTROL: the path-keeping mutant writes a file" "it exited $RC: $OUT"
else
	check "CONTROL: the path-keeping mutant files the entry under a name with a path" \
		"$(grep -c "^machine ${ATTIC_HOST}/codetracer " "$NMP")" "1"
	probe "$NMP" "$ATTIC_HOST" "/codetracer/nix-cache-info"
	check "CONTROL: curl matches that entry against nothing, so the cache gets no credential" \
		"$CRED_PASS" "-"
fi

echo
echo "== 4. file permissions and a reused HOME =="

N4="$TMPROOT/netrc-4"
printf 'machine stale.example.com password LEFT-BY-A-PREVIOUS-JOB\n' >"$N4"
chmod 644 "$N4"
run_writer "$SCRIPT" "$N4" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a netrc left by a previous job is replaced, not appended to" \
	"$(grep -c 'LEFT-BY-A-PREVIOUS-JOB' "$N4")" "0"
check "the replaced file is still mode 600" "$(stat -c '%a' "$N4")" "600"

N4B="$TMPROOT/deep/dir/netrc"
run_writer "$SCRIPT" "$N4B" GH_TOKEN="$GH_TOK"
check "a missing parent directory is created" "$RC" "0"
check "a freshly created netrc is mode 600" "$(stat -c '%a' "$N4B")" "600"
check "no scratch file is left beside it" \
	"$(find "$TMPROOT/deep/dir" -name 'netrc.tmp.*' | wc -l | tr -d ' ')" "0"

# ... and not on the failure path either, where the file holding the github
# token would otherwise outlive the step that was refused.
N4C="$TMPROOT/deep/dir2/netrc"
run_writer "$SCRIPT" "$N4C" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="not-a-url"
check "a refused write leaves no scratch file behind" \
	"$(find "$TMPROOT/deep/dir2" -name 'netrc.tmp.*' | wc -l | tr -d ' ')" "0"

# NEGATIVE CONTROL: the pre-change shape — written straight onto the target
# path, where `umask` cannot reach an existing file's mode. This is how the
# 0644 case above is reached, and it is a real state on the self-hosted runners
# whose $HOME is reused between jobs.
M_INPLACE="$TMPROOT/mutant-inplace.sh"
mutate "$M_INPLACE" \
	'NETRC_TMP="${NETRC_PATH}.tmp.$$"' 'NETRC_TMP="$NETRC_PATH"' \
	'mv -f "$NETRC_TMP" "$NETRC_PATH" || die 2 "cannot install $NETRC_PATH"' ': # mutant: written in place'
N4M="$TMPROOT/netrc-4-mutant"
printf 'machine stale.example.com password LEFT-BY-A-PREVIOUS-JOB\n' >"$N4M"
chmod 644 "$N4M"
run_writer "$M_INPLACE" "$N4M" GH_TOKEN="$GH_TOK"
check "CONTROL: writing in place inherits the old file's mode" "$(stat -c '%a' "$N4M")" "644"

echo
echo "== 5. a token that cannot be filed is a loud failure, never a silent one =="

# Every case here is one where the OLD behaviour — write the github entry and
# say nothing — would leave nix reading the cache anonymously while the job
# looks healthy. That is the failure mode this whole change is about, so none
# of them may be quiet.
NX="$TMPROOT/netrc-x"

run_writer "$SCRIPT" "$NX" GH_TOKEN="$GH_TOK" ATTIC_TOKEN="$ATTIC_TOK"
check "attic-token with an empty endpoint is refused" "$RC" "1"

run_writer "$SCRIPT" "$NX" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="${ATTIC_HOST}/codetracer"
check "an endpoint with no scheme is refused" "$RC" "1"

run_writer "$SCRIPT" "$NX" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="$ATTIC_TOK" ATTIC_ENDPOINT="https://[2001:db8::1]:8443/c"
check "an IPv6-literal endpoint is refused rather than guessed at" "$RC" "1"

run_writer "$SCRIPT" "$NX" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="${ATTIC_TOK}"$'\n' ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a token with a trailing newline is refused, not truncated" "$RC" "1"
case "$OUT" in
*"$ATTIC_TOK"*) bad "the refusal does not echo the token" "the diagnostic contained it" ;;
*) ok "the refusal does not echo the token" ;;
esac

run_writer "$SCRIPT" "$NX" GH_TOKEN=""
check "an empty GH_TOKEN is refused" "$RC" "2"

# NEGATIVE CONTROL: without the whitespace guard the writer succeeds and
# produces an entry whose password is the token up to the space — a truncated
# credential, filed and reported as a success.
M_WS="$TMPROOT/mutant-ws.sh"
mutate "$M_WS" '	*[[:space:]]*)' '	*XXXneverXXX*)'
NMW="$TMPROOT/netrc-mutant-ws"
run_writer "$M_WS" "$NMW" GH_TOKEN="$GH_TOK" \
	ATTIC_TOKEN="${ATTIC_TOK} extra" ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "CONTROL: without the whitespace guard the writer reports success" "$RC" "0"
probe "$NMW" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "CONTROL: and the cache receives a TRUNCATED credential" "$CRED_PASS" "$ATTIC_TOK"

echo
echo "== 6. action.yml actually calls it, with the tokens routed through env =="

if [ -f "$ACTION_YML" ]; then
	# The step under test, isolated. Asserting against the whole manifest would
	# be satisfied by the tokens appearing in the Attic UPLOAD step, which is
	# where they already were while nix had no credential at all — the defect.
	STEP="$TMPROOT/nix-auth-step.yml"
	awk '
		/^    - name: Configure Nix authentication$/ { inside = 1; next }
		inside && /^    - name: / { inside = 0 }
		inside { print }
	' "$ACTION_YML" >"$STEP"
	if [ ! -s "$STEP" ]; then
		bad "the 'Configure Nix authentication' step can be located in action.yml" \
			"the extractor found nothing; this suite would then assert nothing"
	else
		check "the step delegates the netrc to write-nix-netrc.sh" \
			"$(grep -cE '^[[:space:]]*bash "\$\{GITHUB_ACTION_PATH\}/write-nix-netrc\.sh"[[:space:]]*$' "$STEP")" "1"
		# The defect in one line: the action declared the private substituter
		# and then wrote a netrc naming only github.com.
		check "the step no longer writes the netrc inline" \
			"$(grep -c "printf 'machine" "$STEP")" "0"
		check "the step is given the attic token" \
			"$(grep -cE '^[[:space:]]*ATTIC_TOKEN: \$\{\{ inputs\.attic-token \}\}[[:space:]]*$' "$STEP")" "1"
		check "the step is given the attic endpoint" \
			"$(grep -cE '^[[:space:]]*ATTIC_ENDPOINT: \$\{\{ inputs\.attic-endpoint \}\}[[:space:]]*$' "$STEP")" "1"
	fi

	# Interpolating a secret into a `run:` body bakes it into the command file
	# the runner writes to disk and executes, and into any `set -x` trace of it.
	# Routing it through `env:` does not. Same rule configure-git-auth-test.sh
	# enforces for gh-token; `if:` is exempt because a step condition is
	# evaluated by the runner and never written into a script.
	MENTIONS="$(grep -cE '^[[:space:]]*[^#].*inputs\.attic-token' "$ACTION_YML")"
	ALLOWED="$(grep -cE '^[[:space:]]*(ATTIC_TOKEN|attic-token): \$\{\{ inputs\.attic-token \}\}[[:space:]]*$|^[[:space:]]*if: .*inputs\.attic-token' "$ACTION_YML")"
	check "action.yml never interpolates the attic token into a command" \
		"$((MENTIONS - ALLOWED))" "0"
else
	bad "action.yml is present next to this suite"
fi

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "nix-netrc: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "nix-netrc: all contracts hold."
