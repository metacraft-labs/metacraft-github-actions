#!/usr/bin/env bash
#
# assert-action-archive-size.sh — keep every repository this repo's actions
# `uses:` small enough that the Actions runner can actually download it.
#
# WHY THIS EXISTS
# ---------------
# GitHub materialises a composite action by downloading its WHOLE REPOSITORY as
# a zip from codeload, and it resolves the entire action graph during
# `Set up job` — BEFORE any `if:` is evaluated. A nested `uses:` in a composite
# action is therefore not conditional and not free: it is an unconditional
# download charged to every job of every consumer, even the jobs whose `if:`
# would have skipped the step.
#
# The runner applies a fixed 100-second HttpClient.Timeout to each such
# download. It is not configurable, and it is per attempt, retried three times.
# So an action archive is a hard deadline: size/100s is the throughput the
# runner must sustain inside the guest, or the job dies before its first step.
#
# This is not hypothetical. `setup-dev-env` carried
#
#     uses: metacraft-labs/reprobuild/.github/actions/setup-reprobuild@dev
#
# to reach a 21 KB action.yml. Measured from codeload:
#
#     metacraft-labs/reprobuild@f479152            546,170,918 bytes
#     metacraft-labs/metacraft-github-actions@dev      185,806 bytes
#
# 546 MB in 100 s is 5.46 MB/s sustained. A Windows job failed all three
# attempts and died 8m16s into `Set up job`, before `env.ps1` or any workflow
# step ran, with
#
#     ##[error]Action '...' download has timed out.
#
# while four other action archives on the same connection minutes earlier
# (189 KB, 492 KB, ...) downloaded fine. The discriminator was SIZE, not the
# network. reprobuild is 636 MB of tree of which 506 MB is vendored upstream
# release tarballs under `recipes/**/vendor/` — already-compressed, so the zip
# cannot shrink them. That repo is large for a reason that will recur, which is
# exactly why the next `uses:` into a big repo must fail here rather than in
# somebody else's `Set up job`.
#
# Like `assert-composite-run-size.sh`, this guards a property no other suite in
# this repo can see: every suite here EXTRACTS a step body and runs it, which
# works no matter how large the hosting repository is. The size is a property
# only the runner's downloader has an opinion about.
#
# THE BUDGET
# ----------
# The 100-second timeout is fixed, so the budget is a statement about required
# throughput:
#
#     required rate = archive size / 100 s
#
#     546,170,918 B  ->  5.46 MB/s   OBSERVED TO FAIL on eph-win-x64 (3/3)
#         185,806 B  ->  0.002 MB/s  observed to pass, same job, same minute
#      33,554,432 B  ->  0.34 MB/s   this budget
#
# 32 MiB is ~16x below the rate that already failed on this lane. It is not
# derived from a runner bandwidth figure, because none is measurable from here
# and GitHub publishes none; it is set so that the required rate stays an order
# of magnitude under the one demonstrated to be unreachable. Every action this
# repo hosts is well under 1 MB, so the budget leaves two orders of magnitude
# of headroom for legitimate growth while still catching a mistake of the
# vendored-tarball kind.
#
# THE REAL FIX WHEN THIS FIRES
# ----------------------------
# Do NOT raise the budget, and do NOT try to shrink the far repo with
# `.gitattributes` `export-ignore`. export-ignore does work on codeload (both
# the zip and the tar.gz honour it — verified against a repo that ships it),
# but it is the wrong tool twice over: it strips the SAME paths from the
# tarball that `nix`'s `github:` fetcher pulls, so it silently corrupts
# unrelated flake consumers of that repo, and it leaves the archive on the
# critical path of every job, merely smaller.
#
# Move the action into THIS repo instead. The runner keys action archives by
# repo@sha, so an action hosted here is delivered inside the one small archive
# the consumer is already fetching to read `setup-dev-env` — zero additional
# download, and the failure mode is gone rather than made less likely.
#
# HOW THE SIZE IS MEASURED
# ------------------------
# codeload advertises no `Content-Length` and ignores `Range` (measured: a
# `HEAD` returns 200 with no length; `-r 0-0` returns 200, not 206). Neither
# the runner nor this script can pre-flight a size, so it has to be downloaded.
# To keep this guard cheap we read at most BUDGET+1 bytes and stop: under
# budget that yields the exact size, over budget it yields BUDGET+1, which is
# all the verdict needs. Cost is bounded by the budget no matter how large the
# repository is.
#
# Run:  bash .github/assert-action-archive-size.sh [action.yml...]
#       (with no arguments: every */action.yml in the repository)
#
# Env:  ACTION_ARCHIVE_MAX_BYTES  override the budget (used by the negative test)
#       GH_TOKEN / GITHUB_TOKEN   sent as a bearer token so private repos and
#                                 the rate limit behave; optional for public.
set -uo pipefail

# Bytes. See "THE BUDGET" above for why this number.
MAX_BYTES="${ACTION_ARCHIVE_MAX_BYTES:-33554432}"

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
	echo "assert-action-archive-size: no action.yml found under $ROOT." >&2
	echo "  This guard has nothing to measure, which is not the same as a pass." >&2
	exit 2
fi

# Print every cross-repo `uses:` target in $1 as "<owner>/<repo>\t<ref>".
#
# A local `uses: ./thing` costs no download and is skipped. Anything else is
# `owner/repo[/sub/path]@ref`, and the archive the runner fetches is keyed by
# `owner/repo` at `ref` — the subpath is a path INSIDE that archive, which is
# the whole defect this guard exists for.
targets_of() { # <file>
	local file="$1" line stripped spec repo ref
	while IFS= read -r line || [ -n "$line" ]; do
		stripped="${line#"${line%%[![:space:]]*}"}"
		# Skip comments so prose mentioning a `uses:` is not measured. The
		# rationale block in setup-dev-env quotes the very reference this guard
		# was written about, and measuring quoted history would be nonsense.
		case "$stripped" in
		'#'*) continue ;;
		'uses:'*) ;;
		'- uses:'*) stripped="${stripped#- }" ;;
		*) continue ;;
		esac
		spec="${stripped#uses:}"
		spec="${spec#"${spec%%[![:space:]]*}"}"
		spec="${spec%%[[:space:]]*}"
		spec="${spec%\"}"
		spec="${spec#\"}"
		spec="${spec%\'}"
		spec="${spec#\'}"
		# Local path reference: no archive, nothing to measure.
		case "$spec" in
		'./'* | '.\\'* | '') continue ;;
		# docker:// references are not repository archives.
		docker://*) continue ;;
		esac
		case "$spec" in
		*@*) ;;
		*) continue ;;
		esac
		ref="${spec##*@}"
		repo="${spec%@*}"
		# owner/repo, dropping any sub-path.
		repo="$(printf '%s' "$repo" | cut -d/ -f1,2)"
		case "$repo" in
		*/*) printf '%s\t%s\n' "$repo" "$ref" ;;
		esac
	done <"$file"
}

# Echo the size in bytes of the codeload archive for $1@$2, reading at most
# MAX_BYTES+1. Exit non-zero (and print nothing) if it cannot be fetched.
archive_size() { # <owner/repo> <ref>
	local repo="$1" ref="$2" url cap n auth=()
	cap=$((MAX_BYTES + 1))
	# A bare ref works for a SHA; branches and tags need the refs/ form, and
	# codeload accepts the bare name for those too, so use it directly.
	url="https://codeload.github.com/${repo}/zip/${ref}"
	if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
		auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
	fi
	# `head -c` closes the pipe once the cap is reached; curl dies of SIGPIPE,
	# which is the intended early stop, so its exit status is not meaningful
	# here. An unreachable archive is detected by a zero-byte read instead.
	n="$(curl -sfL "${auth[@]}" "$url" 2>/dev/null | head -c "$cap" | wc -c | tr -d ' ')"
	# Retry anonymously when a token was sent and got nothing. Every target here
	# is a public repo, and a job's own `GITHUB_TOKEN` is scoped to ITS
	# repository — codeload may refuse it for a foreign one. Anonymous still
	# works for public archives, so a scoped token must not be able to turn a
	# passing guard into a false failure. (The reverse, dropping to anonymous
	# for a genuinely private repo, still yields nothing and still fails.)
	if { [ -z "$n" ] || [ "$n" -eq 0 ]; } && [ "${#auth[@]}" -gt 0 ]; then
		n="$(curl -sfL "$url" 2>/dev/null | head -c "$cap" | wc -c | tr -d ' ')"
	fi
	if [ -z "$n" ] || [ "$n" -eq 0 ]; then
		return 1
	fi
	printf '%s' "$n"
}

# Collect the distinct (repo, ref) pairs across all files, remembering one
# referring file for each so a failure can name where to look.
declare -a PAIRS=()
declare -a WHERE=()
seen=""
for f in "${FILES[@]}"; do
	if [ ! -f "$f" ]; then
		echo "assert-action-archive-size: no such file: $f" >&2
		exit 2
	fi
	while IFS=$'\t' read -r repo ref; do
		[ -z "$repo" ] && continue
		key="${repo}@${ref}"
		case "$seen" in
		*"|${key}|"*) continue ;;
		esac
		seen="${seen}|${key}|"
		PAIRS+=("$key")
		WHERE+=("${f#"$ROOT"/}")
	done < <(targets_of "$f")
done

if [ "${#PAIRS[@]}" -eq 0 ]; then
	echo "assert-action-archive-size: found no \`uses:\` targets across ${#FILES[@]} file(s)." >&2
	echo "  Either the extractor stopped matching the file format or the actions stopped" >&2
	echo "  referencing anything. Both are guard failures, not passes." >&2
	exit 2
fi

rc=0
i=0
for key in "${PAIRS[@]}"; do
	src="${WHERE[$i]}"
	i=$((i + 1))
	repo="${key%@*}"
	ref="${key##*@}"
	if ! size="$(archive_size "$repo" "$ref")"; then
		echo "FAIL ${key} (from ${src}): could not download the archive to measure it."
		echo "     https://codeload.github.com/${repo}/zip/${ref}"
		echo "     An unmeasurable archive is not a small one. If this is a private repo,"
		echo "     give the job a token with read access; if the ref is gone, fix the \`uses:\`."
		rc=1
		continue
	fi
	rate="$(awk -v b="$size" 'BEGIN { printf "%.2f", b / 100 / 1048576 }')"
	mib="$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1048576 }')"
	if [ "$size" -gt "$MAX_BYTES" ]; then
		echo "FAIL ${key} (from ${src}): archive is over ${MAX_BYTES} bytes (read ${size} and stopped)."
		echo "     The runner downloads this WHOLE repository during \`Set up job\`, for every"
		echo "     job of every consumer, before any \`if:\` is evaluated — against a fixed"
		echo "     100-second HttpClient.Timeout. At this size the guest must sustain more"
		echo "     than ${rate} MB/s or the job dies before its first step."
		echo "     Do not raise the budget and do not reach for \`export-ignore\`; move the"
		echo "     action into this repo, where it ships inside the archive the consumer is"
		echo "     already fetching. See this script's header."
		rc=1
	else
		echo "ok   ${key} (from ${src}): ${size} bytes (${mib} MiB), needs ${rate} MB/s of the 100s budget."
	fi
done

if [ "$rc" -eq 0 ]; then
	echo "assert-action-archive-size: ${#PAIRS[@]} referenced archive(s) within budget (${MAX_BYTES} bytes)."
fi
exit "$rc"
