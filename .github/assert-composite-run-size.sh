#!/usr/bin/env bash
#
# assert-composite-run-size.sh — keep every composite action's `run:` body
# inside what the GitHub Actions template parser will accept.
#
# WHY THIS EXISTS
# ---------------
# A composite action's `run:` body is a template string, and the parser refuses
# one that is too long:
#
#   The template is not valid. metacraft-labs/metacraft-github-actions/main/
#   clone-siblings/action.yml (Line: 165, Col: 12):
#   Exceeded max expression length 21000
#
# That is not a test failure in a consumer's job — it is a TEMPLATE failure, so
# the job never starts, no step of the consumer's workflow runs, and the
# diagnostic names THIS repo's file from inside somebody else's run. Because
# every consumer pins `@main`, one commit here took the mainline CI of every
# repo in the org down at once. It happened on 2026-08-26: `clone-siblings`
# grew 1,419 characters of comment across two commits (fbe8f12, 966579d), and
# from 20:34Z onward every `launcher-recorder-e2e`, `cross-repo-tests` and
# `codetracer.yml` job that used it failed before its first step.
#
# Nothing in this repo's suite noticed, because every suite here EXTRACTS the
# `run:` body and executes it — which works no matter how long it is. The size
# is a property only the GitHub parser has an opinion about, so it needs its
# own guard.
#
# THE BUDGET, AND WHY IT IS NOT 21000
# -----------------------------------
# GitHub documents the limit as 21000 but not what it counts. Measured on the
# real file, against real runs:
#
#   clone-siblings/action.yml @ 3658bad   19468 chars / 19519 UTF-8 bytes  PARSES
#                                         (run 32995543680, 2026-08-26 17:44Z)
#   clone-siblings/action.yml @ 966579d   20887 chars / 20944 UTF-8 bytes  REJECTED
#                                         (run 33009240643, 2026-08-26 20:34Z)
#
# So GitHub's count of that body is at least 21001 while the body itself
# measures 20944 bytes: the parser counts something this script cannot see —
# the step's framing, its `env:` values, or the block scalar's trailing
# newline. The true boundary is therefore UNKNOWN and lies somewhere at or
# below 20887 characters.
#
# The budget below is therefore NOT derived from 21000 — 21000 is denominated
# in units this script cannot observe. It is set just above the largest body
# ever observed to PARSE (19468), which leaves the whole 19468..20887 band —
# where nobody knows which side of the boundary a body falls on — outside the
# budget rather than inside it.
#
# The headroom is small ON PURPOSE. This block must not grow; it must shrink,
# by the extraction described below. Raising this number to make a red run go
# green re-arms exactly the outage it was written after, and does so for every
# repo in the org rather than for this one.
#
# THE REAL FIX WHEN THIS FIRES
# ----------------------------
# Do not shave comments to squeeze under the budget — that trades the
# rationale future readers need for a few hundred characters and leaves the
# next commit in the same position. Move the body into a script FILE beside
# the action and call it:
#
#     run: bash "${GITHUB_ACTION_PATH}/clone-siblings.sh"
#
# which is how `resolve-sibling-rev.sh` already ships. A script file has no
# template limit at all. Shaving comments is the emergency measure; extraction
# is the fix.
#
# Run:  bash .github/assert-composite-run-size.sh [action.yml...]
#       (with no arguments: every */action.yml in the repository)
set -uo pipefail

# Characters. See "THE BUDGET" above for why this number and not 21000.
MAX_CHARS="${COMPOSITE_RUN_MAX_CHARS:-19500}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ "$#" -gt 0 ]; then
	FILES=("$@")
else
	FILES=()
	while IFS= read -r f; do
		FILES+=("$f")
	done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name action.yml -not -path '*/.git/*' | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
	echo "assert-composite-run-size: no action.yml found under $ROOT." >&2
	echo "  This guard has nothing to measure, which is not the same as a pass." >&2
	exit 2
fi

# Emit the DEDENTED body of every `run: |` block in $1, one block at a time, as
# "<startline>\t<body>", NUL-separated so newlines survive.
#
# Dedenting is not cosmetic: a YAML block scalar's value does NOT include the
# block indentation, so the string GitHub measures is the body with that prefix
# removed. Measuring the indented text would overstate `clone-siblings` by
# 3368 characters and make the budget meaningless. The prefix is taken from the
# first non-empty body line, which is how YAML itself determines it.
#
# Pure bash, so the guard needs no more than the action it guards.
blocks_of() { # <file>
	local file="$1" line lineno=0 in_run=0 key_indent="" body_indent="" body="" start=0
	local opened
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		opened=0
		if [ "$in_run" -ne 0 ]; then
			# A non-empty line indented no deeper than the `run:` key ends the
			# block scalar.
			if [ -n "$line" ] && [ "${line#"$key_indent"[[:space:]]}" = "$line" ]; then
				printf '%s\t%s\0' "$start" "$body"
				in_run=0
			else
				if [ -n "$line" ] && [ -z "$body_indent" ]; then
					body_indent="${line%%[![:space:]]*}"
				fi
				body="${body}${line#"$body_indent"}"$'\n'
				continue
			fi
		fi
		# Only a real `run: |` key opens a block, not those words in a comment.
		local stripped="${line#"${line%%[![:space:]]*}"}"
		if [ "$stripped" = "run: |" ] || [ "$stripped" = "run: |-" ]; then
			key_indent="${line%%[![:space:]]*}"
			body_indent=""
			in_run=1
			start="$lineno"
			body=""
			opened=1
		fi
		[ "$opened" -eq 1 ] && continue
	done <"$file"
	[ "$in_run" -eq 1 ] && printf '%s\t%s\0' "$start" "$body"
	return 0
}

rc=0
measured=0
for f in "${FILES[@]}"; do
	if [ ! -f "$f" ]; then
		echo "assert-composite-run-size: no such file: $f" >&2
		rc=2
		continue
	fi
	found=0
	while IFS= read -r -d '' rec; do
		found=1
		measured=$((measured + 1))
		start="${rec%%$'\t'*}"
		body="${rec#*$'\t'}"
		chars="${#body}"
		bytes="$(printf '%s' "$body" | wc -c | tr -d ' ')"
		rel="${f#"$ROOT"/}"
		if [ "$chars" -gt "$MAX_CHARS" ]; then
			echo "FAIL ${rel}:${start} run: block is ${chars} chars (${bytes} UTF-8 bytes); budget is ${MAX_CHARS}."
			echo "     GitHub rejects an over-long composite \`run:\` body at TEMPLATE parse time:"
			echo "       \"Exceeded max expression length 21000\""
			echo "     — which fails every consumer's job before its first step, not this repo's CI."
			echo "     Move the body into a script file beside the action and call it with"
			echo "     \`bash \"\${GITHUB_ACTION_PATH}/<name>.sh\"\`; see this script's header."
			rc=1
		else
			echo "ok   ${rel}:${start} run: block is ${chars} chars (${bytes} UTF-8 bytes), budget ${MAX_CHARS}."
		fi
	done < <(blocks_of "$f")
	if [ "$found" -eq 0 ]; then
		echo "ok   ${f#"$ROOT"/} has no composite \`run: |\` block."
	fi
done

if [ "$measured" -eq 0 ]; then
	echo "assert-composite-run-size: measured zero run: blocks across ${#FILES[@]} file(s)." >&2
	echo "  Either the extractor stopped matching the file format or the actions stopped" >&2
	echo "  being composite. Both are guard failures, not passes." >&2
	exit 2
fi

if [ "$rc" -eq 0 ]; then
	echo "assert-composite-run-size: ${measured} run: block(s) within budget."
fi
exit "$rc"
