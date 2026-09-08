#!/usr/bin/env bash
#
# assert-no-url-embedded-credential.sh — no composite action may put a
# credential in a URL.
#
# WHY THIS EXISTS
# ---------------
# `reprobuild-provision` cloned its siblings like this:
#
#     git clone --depth 1 --branch "$ref" --single-branch \
#       "https://x-access-token:${GH_TOKEN}@github.com/metacraft-labs/${name}.git" ...
#
# which reads as authenticated and is not, because git does not preemptively
# send a URL's userinfo. The first `GET /<repo>/info/refs?service=...` goes out
# ANONYMOUSLY; `Authorization` is attached only if the server answers 401.
#
#   - A PRIVATE repo answers 401, git retries with the credential, and the
#     clone is authenticated. This is why the shape survived review for years:
#     on the repos anyone thought to check, it worked.
#   - A PUBLIC repo answers 200. There is no challenge, so the credential is
#     never sent and the whole clone is anonymous — with the token sitting
#     right there in the URL, looking fine.
#
# Anonymous github.com traffic is rate-limited PER IP and this org's ephemeral
# runner fleet egresses from one address, so those clones fail under ordinary
# fleet load with
#
#     fatal: remote error: GitHub is temporarily limiting some unauthenticated
#     downloads to protect the stability of the platform.
#     -> exit 128
#
# and no indication that a token was present and ignored. That took out
# `codetracer-trace-format-nim`'s `CI (reprobuild)` lane, ~60 seconds into
# `setup-dev-env`, on the public `runquota` — three seconds after the PRIVATE
# `codetracer-native-recorder` had cloned from the same list with the same
# token perfectly well. The asymmetry IS the diagnosis, and nothing in the log
# said so.
#
# WHY A GUARD AND NOT JUST THE FIX
# --------------------------------
# The rest of this repository had already migrated to
# `git-auth/authenticated-clone.sh` (credential-free URL + an owner-scoped
# `http.<url>.extraHeader`, which is sent on EVERY request including the
# first). `authenticated-clone.sh`'s own header documents the URL shape as the
# thing it replaced. `reprobuild-provision` kept it anyway — it arrived later,
# from another repository, and nothing in the suite could see it, because every
# contract suite here extracts a `run:` body and executes it against a local
# server, and a suite that never clones a PUBLIC repo cannot observe this.
#
# So the property needs a guard of its own, and this is it: a `run:` body in a
# composite action manifest may not contain a URL with userinfo.
#
# WHAT IT DELIBERATELY DOES NOT SCAN
# ----------------------------------
# `git-auth/` and `setup-nix/`, whose scripts and contract suites legitimately
# contain the pattern — the suites CONSTRUCT such URLs to prove the credential
# does not survive into a `.git/config`, and the scripts name it in prose to
# say what they replaced. Removing those would remove the tests for this very
# behaviour. The scan targets `*/action.yml` because that is where the defect
# lived and where no other check reaches.
#
# Run:  bash .github/assert-no-url-embedded-credential.sh [action.yml...]
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
	echo "assert-no-url-embedded-credential: no action.yml found under $ROOT." >&2
	echo "  This guard has nothing to scan, which is not the same as a pass." >&2
	exit 2
fi

# `has_userinfo <line>` -- true when the line contains `<scheme>://<a>:<b>@`.
#
# Pure bash pattern matching, so the guard needs no more than the actions it
# guards, and so it behaves identically on the bash 3.2 that ships on GitHub's
# macOS images.
#
# The `@` must come before the next `/`, which is what distinguishes a
# credential in the authority from an `@` living in a path or a query string
# (a `?ref=user@host` would otherwise match).
has_userinfo() { # <line>
	local line="$1" rest authority
	case "$line" in
	*://*) ;;
	*) return 1 ;;
	esac
	while [ -n "$line" ]; do
		rest="${line#*://}"
		[ "$rest" = "$line" ] && return 1
		authority="${rest%%/*}"
		case "$authority" in
		*:*@*) return 0 ;;
		esac
		line="$rest"
	done
	return 1
}

rc=0
scanned=0
hits=0
for f in "${FILES[@]}"; do
	if [ ! -f "$f" ]; then
		echo "assert-no-url-embedded-credential: no such file: $f" >&2
		rc=2
		continue
	fi
	scanned=$((scanned + 1))
	rel="${f#"$ROOT"/}"
	lineno=0
	file_hits=0
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		# Skip YAML comments: a manifest is allowed to DESCRIBE the shape it no
		# longer uses, and several of them now do exactly that.
		stripped="${line#"${line%%[![:space:]]*}"}"
		case "$stripped" in
		'#'*) continue ;;
		esac
		if has_userinfo "$line"; then
			file_hits=$((file_hits + 1))
			hits=$((hits + 1))
			echo "FAIL ${rel}:${lineno} embeds a credential in a URL."
			rc=1
		fi
	done <"$f"
	if [ "$file_hits" -eq 0 ]; then
		echo "ok   ${rel} contains no URL with userinfo."
	fi
done

if [ "$scanned" -eq 0 ]; then
	echo "assert-no-url-embedded-credential: scanned zero files, which is a guard failure and not a pass." >&2
	exit 2
fi

if [ "$rc" -eq 1 ]; then
	echo ""
	echo "A URL of the form https://<user>:<token>@host/... is NOT reliably authenticated."
	echo "Git sends userinfo only AFTER the server answers 401, so a PUBLIC repository —"
	echo "which answers 200 on the first request — is cloned entirely anonymously, and then"
	echo "dies on GitHub's per-IP unauthenticated download limit that this org's whole"
	echo "ephemeral-runner fleet shares:"
	echo ""
	echo "    fatal: remote error: GitHub is temporarily limiting some unauthenticated"
	echo "    downloads to protect the stability of the platform."
	echo ""
	echo "Use the credential-free URL plus the owner-scoped header instead — an"
	echo "extraHeader is sent on every request, including the first:"
	echo ""
	echo "    . \"\${GIT_AUTH_DIR}/scoped-git-auth.sh\""
	echo "    export TOKEN_OWNERS=metacraft-labs"
	echo "    scoped_git_auth_build && scoped_git_auth_export"
	echo "    bash \"\${GIT_AUTH_DIR}/authenticated-clone.sh\" \\"
	echo "      --repo <owner/name> --dest <dir> --rev <ref> --shallow"
	echo ""
	echo "See git-auth/authenticated-clone.sh and this script's header."
	exit 1
fi

echo "assert-no-url-embedded-credential: ${scanned} manifest(s) scanned, no URL carries a credential."
exit 0
