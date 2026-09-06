#!/usr/bin/env bash
#
# assert-no-expression-in-manifest-prose.sh — keep `${{ ... }}` out of the
# action-manifest fields GitHub evaluates against a context that has none.
#
# WHY THIS EXISTS
# ---------------
# An action's `description:` is not a comment. GitHub's ActionManifestManager
# runs the template engine over the manifest, and it evaluates `${{ ... }}`
# wherever it appears — including in `name:` and `description:`, which are
# evaluated against a context that does NOT contain `github`. Prose that quotes
# an expression is therefore not a quotation, it is code, and it fails at parse
# time.
#
# This is not hypothetical. `setup-reprobuild/action.yml` was moved into this
# repo with a comment in its `description:` explaining that it resolves its
# helper through the `github.action_path` context, written in the double-brace
# expression form. Every consumer's job then died in `Set up job`, before its
# first step, with
#
#     setup-reprobuild/action.yml (Line: 2, Col: 14): Unrecognized named-value:
#     'github'. Located at position 1 within expression: github.action_path
#     ##[error]Failed to load .../setup-reprobuild/action.yml
#
# and, because this repo is a shared mainline, it did so in all 64 repos that
# reference `setup-dev-env`. The blast radius is identical to the two other
# properties this directory guards: one file, every consumer, before any step
# they could have used to notice.
#
# WHAT IS AND IS NOT CHECKED
# --------------------------
# Flagged: top-level `name:`, `description:`, `author:`, `branding:`, and the
# `description:` of every entry under `inputs:` / `outputs:`. These are pure
# metadata; an expression in them is always a mistake.
#
# Not flagged: everything under `runs:` (that is where expressions belong and
# where the full context exists), `inputs.*.default`, and `outputs.*.value`
# (composite actions legitimately compute those). This guard is deliberately
# narrow so that it has no false positives and nobody is tempted to disable it.
#
# THE FIX WHEN THIS FIRES
# -----------------------
# Name the context in prose — `github.action_path`, not the expression form.
# Do not try to escape it: the escape (`${{ '${{' }}`) is itself an expression,
# which is how you get a second, more confusing template error.
#
# Run:  bash .github/assert-no-expression-in-manifest-prose.sh [action.yml...]
#       (with no arguments: every */action.yml in the repository)
set -uo pipefail

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
	echo "assert-no-expression-in-manifest-prose: no action.yml found under $ROOT." >&2
	echo "  This guard has nothing to check, which is not the same as a pass." >&2
	exit 2
fi

rc=0
checked=0

# Report every line inside a context-free metadata field that carries `${{`.
#
# The scan is line-based and tracks two things: which TOP-LEVEL key we are
# under, and — inside `inputs:`/`outputs:` — whether we are inside an entry's
# `description:` value. Block scalars (`>` / `|`) are handled by continuing to
# treat deeper-indented lines as part of the value until a line at or above the
# key's own indentation starts something else.
scan() { # <file>
	local file="$1"
	local line stripped indent top="" in_desc=0 desc_indent=0 lineno=0
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		[ -z "$stripped" ] && continue
		indent=$((${#line} - ${#stripped}))

		# A new top-level key resets everything.
		if [ "$indent" -eq 0 ]; then
			case "$stripped" in
			*:*)
				top="${stripped%%:*}"
				in_desc=0
				# A top-level metadata key's own value may be inline.
				case "$top" in
				name | description | author | branding)
					in_desc=1
					desc_indent=0
					;;
				esac
				;;
			esac
		elif [ "$in_desc" -eq 1 ] && [ "$indent" -le "$desc_indent" ]; then
			# Left the description value (same or shallower indentation).
			in_desc=0
		fi

		# Inside inputs:/outputs:, an entry's `description:` opens a value.
		if [ "$top" = "inputs" ] || [ "$top" = "outputs" ]; then
			case "$stripped" in
			description:*)
				in_desc=1
				desc_indent="$indent"
				;;
			*:*)
				if [ "$in_desc" -eq 1 ] && [ "$indent" -le "$desc_indent" ]; then
					in_desc=0
				fi
				;;
			esac
		fi

		if [ "$in_desc" -eq 1 ] && [[ "$line" == *'${{'* ]]; then
			echo "FAIL ${file#"$ROOT"/}:${lineno}: \`\${{ ... }}\` inside \`${top}:\`, which GitHub"
			echo "     evaluates against a context that has no \`github\`. This is not a quotation,"
			echo "     it is a template error that fails every consumer's \`Set up job\`:"
			echo "       ${stripped}"
			echo "     Name the context in prose instead (e.g. \`github.action_path\`). Do not try"
			echo "     to escape it — the escape is itself an expression."
			rc=1
		fi
	done <"$file"
}

for f in "${FILES[@]}"; do
	if [ ! -f "$f" ]; then
		echo "assert-no-expression-in-manifest-prose: no such file: $f" >&2
		exit 2
	fi
	scan "$f"
	checked=$((checked + 1))
done

if [ "$rc" -eq 0 ]; then
	echo "assert-no-expression-in-manifest-prose: ${checked} manifest(s) clean."
fi
exit "$rc"
