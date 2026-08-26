#!/usr/bin/env bash
#
# anchor-workspace-lock-test.sh — contract suite for the re-anchoring transform.
#
# WHAT THIS SUITE IS DEFENDING
# ----------------------------
# The transform's whole value is that it changes ONE thing. A lock record
# carries ~130 sibling pins; the mainline commit's record must carry the same
# ~130 pins and differ from its source in exactly the record's own coordinate.
# Every plausible defect here is silent: rewriting a sibling's revision to the
# merge SHA, rewriting nothing and publishing a record that contradicts its own
# filename, rewriting the WRONG `[[repo]]` because a name matched by prefix, or
# re-filing a routed participation record that names no sibling at all and so
# still reads as "unlocked" at the new commit.
#
# NO MOCKS. The subject is a pure text transform over real record bodies —
# including one lifted, unmodified, from metacraft-manifests@latest (the record
# the pre-push gate published for the head of codetracer PR #652) — so there is
# nothing to substitute. Assertions are made on bytes: the suite diffs the
# output against the input and demands that the set of differing lines be
# exactly the one expected line, which is the only assertion shape that can
# distinguish "changed the right thing" from "changed the right thing and
# something else".
#
# Run: bash publish-workspace-lock/anchor-workspace-lock-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/anchor-workspace-lock.sh"

[[ -f $SUT ]] || {
	echo "anchor-workspace-lock-test: cannot find $SUT" >&2
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
contains() { # <desc> <haystack> <needle>
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "did not contain [$3]" ;;
	esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DST="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OTHER="cccccccccccccccccccccccccccccccccccccccc"

OUT=""
ERR=""
RC=0
run() { # <args...>
	local errf="$TMP/err"
	OUT="$(bash "$SUT" "$@" 2>"$errf")"
	RC=$?
	ERR="$(<"$errf")"
}

# ===========================================================================
# 1. The TOML happy path: exactly one line moves, and it is the right one.
# ===========================================================================
mk_toml() { # <file> <self-revision>
	{
		printf 'schema = "reprobuild.workspace.lock.v1"\n\n'
		printf '[lock]\nproject = "codetracer"\ncreated_at = "2026-08-24T21:44:02Z"\ncreated_by = "repro workspace lock"\n\n'
		printf '[[repo]]\nname = "infra"\npath = "infra"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "live"\n\n' "$OTHER"
		printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "feature"\n\n' "$2"
		printf '[[repo]]\nname = "codetracer-nim"\npath = "codetracer-nim"\nremote = "metacraft-labs"\nrevision = "%s"\nbranch = "dev"\n' "$OTHER"
	} >"$1"
}

IN="$TMP/lock.toml"
GOT="$TMP/out.toml"
mk_toml "$IN" "$SRC"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN" --out "$GOT"
check "toml: re-anchoring a well-formed record succeeds" "$RC" "0"

DIFF="$(diff "$IN" "$GOT")"
check "toml: the record's own revision now names the mainline commit" \
	"$(grep -c "revision = \"$DST\"" "$GOT")" "1"
check "toml: and the head SHA is gone from the record entirely" \
	"$(grep -c "$SRC" "$GOT")" "0"
# The decisive shape: the ONLY differing lines are that one revision pair.
check "toml: exactly one line differs from the source record" \
	"$(printf '%s\n' "$DIFF" | grep -c '^[<>]')" "2"
contains "toml: ...and the removed line is the self revision" "$DIFF" "< revision = \"$SRC\""
contains "toml: ...and the added line is the same key at the new SHA" "$DIFF" "> revision = \"$DST\""
check "toml: every sibling pin is preserved byte-for-byte" \
	"$(grep -c "revision = \"$OTHER\"" "$GOT")" "2"
check "toml: the byte count is unchanged (a SHA is a SHA)" \
	"$(wc -c <"$IN" | tr -d ' ')" "$(wc -c <"$GOT" | tr -d ' ')"

# Without `--out` the record goes to stdout. That is the mode a human reaches
# for when checking what would be published, so it must produce the same bytes
# rather than a debug rendering of them.
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN"
check "toml: with no --out the record is written to stdout" "$RC" "0"
check "toml: ...and it is byte-identical to what --out writes" "$OUT" "$(<"$GOT")"

# The `codetracer-nim` entry exists precisely so a prefix match would be caught:
# a transform matching `name = "codetracer"` as a prefix would move it too.
check "toml: a sibling whose name EXTENDS the repo name is not touched" \
	"$(grep -A4 'name = "codetracer-nim"' "$GOT" | grep -c "revision = \"$OTHER\"")" "1"

# ===========================================================================
# 2. TOML refusals. Each is a record that must never be re-filed.
# ===========================================================================

# 2a. No entry for SELF -> exit 4. Such a record does not anchor itself, so it
#     is not the record for the source commit.
IN2="$TMP/no-self.toml"
{
	printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nproject = "codetracer"\ncreated_at = "x"\n\n'
	printf '[[repo]]\nname = "infra"\npath = "infra"\nremote = "m"\nrevision = "%s"\n' "$OTHER"
} >"$IN2"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN2"
check "toml: a record that does not name the repo itself is refused (exit 4)" "$RC" "4"
contains "toml: ...and says the record does not anchor itself" "$ERR" "does not anchor itself"

# 2b. Self entry pinned at a DIFFERENT commit -> exit 4. This is the defect that
#     would publish someone else's sibling set under our SHA.
IN3="$TMP/wrong-anchor.toml"
mk_toml "$IN3" "$OTHER"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN3"
check "toml: a record anchoring the repo at another commit is refused (exit 4)" "$RC" "4"
contains "toml: ...and says whose sibling set would have been published" "$ERR" "someone else's sibling set"

# 2c. Two entries for SELF -> exit 5. Which one is the coordinate is undecidable.
IN4="$TMP/dup.toml"
{
	printf 'schema = "reprobuild.workspace.lock.v1"\n\n[lock]\nproject = "codetracer"\ncreated_at = "x"\n\n'
	printf '[[repo]]\nname = "codetracer"\npath = "a"\nremote = "m"\nrevision = "%s"\n\n' "$SRC"
	printf '[[repo]]\nname = "codetracer"\npath = "b"\nremote = "m"\nrevision = "%s"\n' "$SRC"
} >"$IN4"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN4"
check "toml: a record anchoring the repo twice is refused (exit 5)" "$RC" "5"
contains "toml: ...and says the coordinate is not decidable" "$ERR" "not decidable"

# 2d. A ROUTED PARTICIPATION RECORD -> exit 3, and specifically not 5. It is a
#     well-formed artifact of routed locking mode that pins only its own repo;
#     `resolve-sibling-rev.sh` reads it as UNLOCKED, so re-filing it would
#     publish a record that leaves the symptom in place.
IN5="$TMP/participation.toml"
printf '[[repo]]\nname = "codetracer"\npath = "codetracer"\nrevision = "%s"\n' "$SRC" >"$IN5"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN5"
check "toml: a routed participation record is refused (exit 3)" "$RC" "3"
contains "toml: ...named as what it is, not as a broken lock" "$ERR" "PARTICIPATION RECORD"
contains "toml: ...and says it would still read as unlocked" "$ERR" "reads as unlocked"

# 2e. A schema-less document that DOES name a foreign repo is not a
#     participation record — it is a lock that failed to declare itself, and it
#     is refused as malformed rather than quietly re-filed.
IN6="$TMP/schemaless.toml"
{
	printf '[[repo]]\nname = "codetracer"\npath = "a"\nrevision = "%s"\n\n' "$SRC"
	printf '[[repo]]\nname = "infra"\npath = "infra"\nrevision = "%s"\n' "$OTHER"
} >"$IN6"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$IN6"
check "toml: a schema-less document naming a sibling is refused (exit 5)" "$RC" "5"
contains "toml: ...and says why (no schema key)" "$ERR" "declares no top-level 'schema'"

# ===========================================================================
# 3. Usage refusals — every one of these values reaches a git command line or a
#    published FILENAME downstream.
# ===========================================================================
run --repo codetracer --source-sha "main" --target-sha "$DST" --in "$IN"
check "usage: a source revision that is not a SHA is refused" "$RC" "2"
run --repo codetracer --source-sha "$SRC" --target-sha "dev" --in "$IN"
check "usage: a target revision that is not a SHA is refused" "$RC" "2"
run --repo codetracer --source-sha "$SRC" --target-sha "${DST:0:12}" --in "$IN"
check "usage: an abbreviated target SHA is refused" "$RC" "2"
run --repo codetracer --source-sha "$SRC" --target-sha "$SRC" --in "$IN"
check "usage: re-anchoring a commit onto itself is refused" "$RC" "2"
run --repo "codetracer;rm -rf /" --source-sha "$SRC" --target-sha "$DST" --in "$IN"
check "usage: a repo name outside [0-9A-Za-z._-] is refused" "$RC" "2"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$TMP/lock.json"
check "usage: a record whose extension is neither .toml nor .xml is refused" "$RC" "2"

# ===========================================================================
# 4. The legacy repo-workspaces XML layout. Still the majority of what lands in
#    metacraft-manifests, so it is not an afterthought here either.
# ===========================================================================
mk_xml() { # <file> <self-revision>
	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<manifest>\n'
		printf '  <remote name="metacraft-labs" fetch="https://github.com/metacraft-labs"/>\n'
		printf '  <project name="infra" path="infra" remote="metacraft-labs" revision="%s" upstream="live"/>\n' "$OTHER"
		printf '  <project name="codetracer" remote="metacraft-labs" revision="%s" upstream="dev" dest-branch="dev"/>\n' "$2"
		printf '  <project name="codetracer-nim" path="codetracer-nim" remote="metacraft-labs" revision="%s" upstream="dev"/>\n' "$OTHER"
		printf '</manifest>\n'
	} >"$1"
}
XIN="$TMP/lock.xml"
XGOT="$TMP/out.xml"
mk_xml "$XIN" "$SRC"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$XIN" --out "$XGOT"
check "xml: re-anchoring a well-formed snapshot succeeds" "$RC" "0"
XDIFF="$(diff "$XIN" "$XGOT")"
check "xml: exactly one line differs from the source snapshot" \
	"$(printf '%s\n' "$XDIFF" | grep -c '^[<>]')" "2"
contains "xml: the changed line is the repo's own <project> element" "$XDIFF" ">   <project name=\"codetracer\" remote=\"metacraft-labs\" revision=\"$DST\" upstream=\"dev\""
check "xml: the head SHA is gone" "$(grep -c "$SRC" "$XGOT")" "0"
check "xml: a sibling whose name EXTENDS the repo name is not touched" \
	"$(grep -c "name=\"codetracer-nim\" path=\"codetracer-nim\" remote=\"metacraft-labs\" revision=\"$OTHER\"" "$XGOT")" "1"

XIN2="$TMP/wrong.xml"
mk_xml "$XIN2" "$OTHER"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$XIN2"
check "xml: a snapshot anchoring the repo at another commit is refused (exit 4)" "$RC" "4"
# By the right route: the element WAS found and its revision disagreed. Without
# this the case would also pass if the matcher had simply failed to see the
# element at all, which is the defect that made this suite red the first time.
contains "xml: ...because the revision disagreed, not because nothing matched" "$ERR" "at a different commit than --source-sha"

XIN3="$TMP/nomanifest.xml"
printf '<project name="codetracer" revision="%s"/>\n' "$SRC" >"$XIN3"
run --repo codetracer --source-sha "$SRC" --target-sha "$DST" --in "$XIN3"
check "xml: a fragment with no <manifest> element is refused (exit 5)" "$RC" "5"

# ===========================================================================
# 5. Against the real thing.
#
# A synthetic fixture proves the transform handles the shapes this suite
# imagines. This case proves it handles the shape that actually ships: the
# record metacraft-manifests@latest carries for the head of codetracer PR #652,
# 131 pins, checked in here verbatim.
# ===========================================================================
REAL="$HERE/testdata/codetracer-pr652-head.toml"
if [[ -f $REAL ]]; then
	REAL_SRC="a820eb1df159d9cda2f28dae7d308a04dfe5aa3f"
	REAL_DST="d4c09c320a7ed0d75f63774e1b8b2b15b358a9f2"
	RGOT="$TMP/real.toml"
	run --repo codetracer --source-sha "$REAL_SRC" --target-sha "$REAL_DST" --in "$REAL" --out "$RGOT"
	check "real record: re-anchors" "$RC" "0"
	RDIFF="$(diff "$REAL" "$RGOT")"
	check "real record: exactly one line differs" \
		"$(printf '%s\n' "$RDIFF" | grep -c '^[<>]')" "2"
	contains "real record: and it is the codetracer coordinate" "$RDIFF" "> revision = \"$REAL_DST\""
	check "real record: all 131 pins survive" \
		"$(grep -c '^\[\[repo\]\]$' "$RGOT")" "$(grep -c '^\[\[repo\]\]$' "$REAL")"
	check "real record: byte count unchanged" \
		"$(wc -c <"$REAL" | tr -d ' ')" "$(wc -c <"$RGOT" | tr -d ' ')"
else
	bad "real record: fixture present at publish-workspace-lock/testdata/codetracer-pr652-head.toml" \
		"missing — this suite's only non-synthetic input"
fi

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [[ $FAIL -gt 0 ]]; then
	echo "anchor-workspace-lock: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "anchor-workspace-lock: all contracts hold."
