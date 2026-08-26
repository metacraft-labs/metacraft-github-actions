#!/usr/bin/env bash
#
# anchor-workspace-lock.sh — re-anchor a published workspace lock record from
# the commit it was written for onto the mainline commit that landed it.
#
# WHY THIS EXISTS
# ---------------
# Workspace lock records are published by the LOCAL pre-push gate: every commit
# that leaves a developer's workspace gets a
# `locks/<project>/<repo>/<sha>.toml` (or a legacy repo-workspaces
# `<sha>.xml`) in the manifests repo. That gate is the only publisher, and it
# runs on a machine that has the workspace.
#
# A PR-based repo's mainline commits are not born on such a machine. GitHub
# creates them server-side — a merge commit, a squash, or a rebase replay —
# and no hook runs. So on `metacraft-labs/codetracer@dev` and
# `metacraft-labs/infra@live` NOT ONE first-parent mainline commit carries a
# lock, while the PR heads that produced them all do. `clone-siblings` probes
# exactly those mainline commits (`pull_request` -> `base.sha`, `push` ->
# `github.sha` / `github.event.before`), so every job that needs a sibling
# revision dies at "No workspace lock for <repo>" before it reaches a build.
#
# WHAT IS RE-ANCHORED, AND WHY THAT AND NOT SOMETHING ELSE
# --------------------------------------------------------
# The sibling set recorded for the mainline commit is the sibling set of the
# PR HEAD's lock — the record the pre-push gate published for the very content
# being landed. That is the only artifact in existence that describes what
# this change needs, and it is the one that carries a sibling bump the PR
# itself made. (Resolving the mainline commit against the PR BASE instead —
# which is what an ancestry walk amounts to — pins the state that predates the
# merge, and is exactly wrong for a PR that changed sibling requirements.)
#
# Every `[[repo]]` pin is therefore copied VERBATIM. Precisely one field
# changes: the record's own coordinate — the `[[repo]]` entry naming SELF,
# whose `revision` moves from the PR head SHA to the mainline SHA.
#
# That rewrite is not cosmetic, it is REQUIRED. A lock record is bound to its
# filename: reprobuild's publisher (`expectedLockRecordFromBody`) accepts a
# staged record only when the body carries a `[[repo]]` whose `name` is the
# repo path component and whose `revision` is the SHA in the filename. A
# byte-for-byte copy under a new filename would be a record that contradicts
# its own key — it would claim the repo is at the PR head while filed under
# the mainline commit.
#
# NOTHING ELSE IS ADDED. No provenance key, no marker table: the record schema
# is read in STRICT mode (`reader.nim`'s `decodeStrict` deliberately does not
# set `TomlUnknownFields`), so an extra key would make the record unreadable
# by the tool that owns it. Provenance lives in the publishing commit message,
# which is where it can say anything at all without becoming a schema change.
#
# Usage:
#   anchor-workspace-lock.sh --repo NAME --source-sha SHA --target-sha SHA \
#       --in FILE [--out FILE]
#
#   --repo NAME       the repo the record is filed under (its lock-path
#                     component). Must be a plain GitHub repo name.
#   --source-sha SHA  the commit the record was published for (the PR head).
#   --target-sha SHA  the commit to re-anchor onto (the mainline commit).
#   --in FILE         the published record. `.toml` (reprobuild) or `.xml`
#                     (legacy repo-workspaces); the format is taken from the
#                     extension, because that is what the resolver keys on too.
#   --out FILE        where to write the re-anchored record. Default: stdout.
#
# Exit codes:
#   0  re-anchored
#   2  usage error
#   3  the input is a ROUTED PARTICIPATION RECORD, not a lock. It pins only the
#      repo whose directory it sits in, so it can never answer a question about
#      a sibling and re-anchoring it would publish a record that reads as
#      "unlocked" (resolve-sibling-rev exit 3) at the new SHA as well.
#   4  the input does not anchor SELF at --source-sha: it carries no entry for
#      --repo, or that entry's revision is some other commit. Either way this
#      record is not the record for that commit and must not be re-filed.
#   5  the input is malformed for this purpose: not a lock document, or it
#      anchors SELF more than once.
#
# Contract suite: ./anchor-workspace-lock-test.sh
set -euo pipefail

ME="anchor-workspace-lock"

REPO=""
SRC_SHA=""
DST_SHA=""
IN_FILE=""
OUT_FILE=""

usage() {
	echo "usage: $ME --repo NAME --source-sha SHA --target-sha SHA --in FILE [--out FILE]" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO="${2:-}"
		shift 2 || usage
		;;
	--source-sha)
		SRC_SHA="${2:-}"
		shift 2 || usage
		;;
	--target-sha)
		DST_SHA="${2:-}"
		shift 2 || usage
		;;
	--in)
		IN_FILE="${2:-}"
		shift 2 || usage
		;;
	--out)
		OUT_FILE="${2:-}"
		shift 2 || usage
		;;
	--repo=*)
		REPO="${1#--repo=}"
		shift
		;;
	--source-sha=*)
		SRC_SHA="${1#--source-sha=}"
		shift
		;;
	--target-sha=*)
		DST_SHA="${1#--target-sha=}"
		shift
		;;
	--in=*)
		IN_FILE="${1#--in=}"
		shift
		;;
	--out=*)
		OUT_FILE="${1#--out=}"
		shift
		;;
	*)
		echo "$ME: unknown argument: $1" >&2
		usage
		;;
	esac
done

[ -n "$REPO" ] || usage
[ -n "$SRC_SHA" ] || usage
[ -n "$DST_SHA" ] || usage
[ -n "$IN_FILE" ] || usage

# A repo NAME that needs percent-encoding to become a lock-path component is
# refused rather than guessed at. `encodeLockPathSegment` leaves a plain GitHub
# repo name alone, and every repo this runs for is one; a name outside that set
# (a `owner/name` reference project, a Windows reserved stem) would make the
# path component and the `[[repo]] name` two different strings, and silently
# matching the wrong one is how a lock record acquires someone else's revision.
case "$REPO" in
*[!0-9A-Za-z._-]* | "" | -* | .*)
	echo "$ME: --repo must be a plain GitHub repo name ([0-9A-Za-z._-], not starting with '-' or '.'); got '$REPO'" >&2
	exit 2
	;;
esac

check_sha() { # <label> <value>
	case "$2" in
	*[!0-9a-f]*)
		echo "$ME: $1 must be a 40-character lowercase hex commit SHA; got '$2'" >&2
		exit 2
		;;
	esac
	if [ ${#2} -ne 40 ]; then
		echo "$ME: $1 must be a 40-character lowercase hex commit SHA; got '$2'" >&2
		exit 2
	fi
}
check_sha "--source-sha" "$SRC_SHA"
check_sha "--target-sha" "$DST_SHA"

if [ "$SRC_SHA" = "$DST_SHA" ]; then
	echo "$ME: --source-sha and --target-sha are the same commit ($SRC_SHA); there is nothing to re-anchor." >&2
	exit 2
fi

[ -f "$IN_FILE" ] || {
	echo "$ME: no such file: $IN_FILE" >&2
	exit 2
}

FORMAT=""
case "$IN_FILE" in
*.toml) FORMAT=toml ;;
*.xml) FORMAT=xml ;;
*)
	echo "$ME: --in must name a .toml (reprobuild) or .xml (repo-workspaces) lock record; got '$IN_FILE'" >&2
	exit 2
	;;
esac

# ---------------------------------------------------------------------------
# Read the record into a line array, remembering whether it ended in a newline.
#
# Everything below rewrites ONE line and re-emits the rest untouched, including
# any CR a Windows-authored record carries, so the published bytes differ from
# the source record in exactly the substitution this tool is named for.
# ---------------------------------------------------------------------------
declare -a LINES=()
FINAL_NEWLINE=1
__line=""
while IFS= read -r __line; do
	LINES+=("$__line")
done <"$IN_FILE"
# `read` fails on the last line when it is unterminated, having already put the
# partial content in $__line. Appending it here is what keeps a record without a
# trailing newline byte-stable through this tool.
if [ -n "$__line" ]; then
	LINES+=("$__line")
	FINAL_NEWLINE=0
fi

emit() {
	local i n
	n=${#LINES[@]}
	i=0
	while [ $i -lt $n ]; do
		if [ $((i + 1)) -eq $n ] && [ $FINAL_NEWLINE -eq 0 ]; then
			printf '%s' "${LINES[$i]}"
		else
			printf '%s\n' "${LINES[$i]}"
		fi
		i=$((i + 1))
	done
}

trim() { # <string> -> TRIMMED
	local s="$1"
	while [ "${s#[[:space:]]}" != "$s" ]; do s="${s#[[:space:]]}"; done
	while [ "${s%[[:space:]]}" != "$s" ]; do s="${s%[[:space:]]}"; done
	TRIMMED="$s"
}

unquote() { # <string> -> UNQUOTED
	local v="$1"
	case "$v" in
	\"*\")
		v="${v#\"}"
		v="${v%\"}"
		;;
	\'*\')
		v="${v#\'}"
		v="${v%\'}"
		;;
	esac
	UNQUOTED="$v"
}

anchor_toml() {
	local i n line raw key val
	local tables=0 repo_tables=0 names=0 foreign=0 has_schema=0
	local in_repo_table=0 cur_name="" cur_rev="" cur_rev_line=-1
	local hit_line=-1 hits=0

	n=${#LINES[@]}
	i=0
	while [ $i -lt $n ]; do
		raw="${LINES[$i]}"
		line="${raw%$'\r'}"
		trim "$line"
		line="$TRIMMED"
		i=$((i + 1))
		[ -z "$line" ] && continue
		case "$line" in \#*) continue ;; esac

		case "$line" in
		"["*)
			# A table header closes the previous one. Decide the previous
			# `[[repo]]` table now, while its keys are still in hand.
			if [ $in_repo_table -eq 1 ] && [ "$cur_name" = "$REPO" ]; then
				hits=$((hits + 1))
				if [ "$cur_rev" = "$SRC_SHA" ]; then hit_line=$cur_rev_line; fi
			fi
			tables=$((tables + 1))
			if [ "$line" = "[[repo]]" ]; then
				repo_tables=$((repo_tables + 1))
				in_repo_table=1
			else
				in_repo_table=0
			fi
			cur_name=""
			cur_rev=""
			cur_rev_line=-1
			continue
			;;
		esac

		key="${line%%=*}"
		[ "$key" = "$line" ] && continue
		val="${line#*=}"
		trim "$key"
		key="$TRIMMED"
		trim "$val"
		unquote "$TRIMMED"
		val="$UNQUOTED"

		if [ $tables -eq 0 ] && [ "$key" = "schema" ]; then
			has_schema=1
			continue
		fi
		if [ $in_repo_table -eq 1 ]; then
			case "$key" in
			name)
				cur_name="$val"
				names=$((names + 1))
				[ "$val" != "$REPO" ] && foreign=1
				;;
			revision)
				cur_rev="$val"
				cur_rev_line=$((i - 1))
				;;
			esac
		fi
	done
	# EOF closes the last table too.
	if [ $in_repo_table -eq 1 ] && [ "$cur_name" = "$REPO" ]; then
		hits=$((hits + 1))
		if [ "$cur_rev" = "$SRC_SHA" ]; then hit_line=$cur_rev_line; fi
	fi

	# A routed participation record: no top-level `schema`, nothing but
	# `[[repo]]` tables, and no repo named but SELF. Same rule the resolver
	# applies in `is_participation_record`, and for the same reason.
	if [ $has_schema -eq 0 ] && [ $repo_tables -gt 0 ] &&
		[ $tables -eq $repo_tables ] && [ $names -gt 0 ] && [ $foreign -eq 0 ]; then
		echo "$ME: $IN_FILE is a routed per-repo PARTICIPATION RECORD, not a workspace lock: it pins only '$REPO' itself, so it names no sibling and cannot answer a sibling query at any commit. Re-anchoring it would file a record that still reads as unlocked. Publish a real lock for $SRC_SHA first ('repro workspace lock')." >&2
		exit 3
	fi
	if [ $has_schema -eq 0 ]; then
		echo "$ME: $IN_FILE declares no top-level 'schema' key, so it is not a reprobuild.workspace.lock.v1 document and must not be re-filed under another commit." >&2
		exit 5
	fi
	if [ $hits -gt 1 ]; then
		echo "$ME: $IN_FILE carries $hits [[repo]] entries named '$REPO'. A lock record anchors its own repo exactly once; which of them is the record's coordinate is not decidable here." >&2
		exit 5
	fi
	if [ $hits -eq 0 ]; then
		echo "$ME: $IN_FILE carries no [[repo]] entry named '$REPO', so it does not anchor itself and cannot be re-anchored onto $DST_SHA." >&2
		exit 4
	fi
	if [ $hit_line -lt 0 ]; then
		echo "$ME: $IN_FILE anchors '$REPO' at a different commit than --source-sha $SRC_SHA. This record is not the record for that commit; re-filing it under $DST_SHA would publish someone else's sibling set." >&2
		exit 4
	fi

	raw="${LINES[$hit_line]}"
	LINES[$hit_line]="${raw/$SRC_SHA/$DST_SHA}"
}

anchor_xml() {
	local i n raw line hits=0 hit_line=-1 has_manifest=0

	n=${#LINES[@]}
	i=0
	while [ $i -lt $n ]; do
		raw="${LINES[$i]}"
		line="${raw%$'\r'}"
		case "$line" in
		*"<manifest"*) has_manifest=1 ;;
		esac
		# `name` may or may not be the first attribute, and an attribute whose
		# NAME merely ends in `name` (a hypothetical `dest-name=`) must not
		# count — hence the required `<project ` prefix or leading space.
		case "$line" in
		*"<project"*)
			case "$line" in
			*"<project name=\"$REPO\""* | *" name=\"$REPO\""*)
				hits=$((hits + 1))
				case "$line" in
				*"revision=\"$SRC_SHA\""*) hit_line=$i ;;
				esac
				;;
			esac
			;;
		esac
		i=$((i + 1))
	done

	if [ $has_manifest -eq 0 ]; then
		echo "$ME: $IN_FILE carries no <manifest> element, so it is not a repo-workspaces lock snapshot and must not be re-filed under another commit." >&2
		exit 5
	fi
	if [ $hits -gt 1 ]; then
		echo "$ME: $IN_FILE carries $hits <project name=\"$REPO\"> elements. A lock snapshot anchors its own repo exactly once; which of them is the record's coordinate is not decidable here." >&2
		exit 5
	fi
	if [ $hits -eq 0 ]; then
		echo "$ME: $IN_FILE carries no <project name=\"$REPO\"> element, so it does not anchor itself and cannot be re-anchored onto $DST_SHA." >&2
		exit 4
	fi
	if [ $hit_line -lt 0 ]; then
		echo "$ME: $IN_FILE anchors '$REPO' at a different commit than --source-sha $SRC_SHA. This record is not the record for that commit; re-filing it under $DST_SHA would publish someone else's sibling set." >&2
		exit 4
	fi

	raw="${LINES[$hit_line]}"
	# Only this element's own revision moves. A second `revision="..."` on the
	# same line would make "this element's own" ambiguous, and a lock snapshot
	# that spells one element across several lines is outside what this
	# line-oriented rewrite can claim to have done correctly.
	line="${raw#*revision=\"}"
	case "$line" in
	*"revision=\""*)
		echo "$ME: the <project name=\"$REPO\"> element in $IN_FILE carries more than one revision= attribute on its line; refusing to guess which one is its coordinate." >&2
		exit 5
		;;
	esac
	LINES[$hit_line]="${raw/revision=\"$SRC_SHA\"/revision=\"$DST_SHA\"}"
}

case "$FORMAT" in
toml) anchor_toml ;;
xml) anchor_xml ;;
esac

if [ -n "$OUT_FILE" ]; then
	emit >"$OUT_FILE"
else
	emit
fi
