#!/usr/bin/env bash
#
# write-nix-netrc.sh — write the netrc that NIX reads, for github.com and, when
# a token for it is supplied, for the private Attic binary cache.
#
# WHY THE ATTIC HALF EXISTS
# -------------------------
# `setup-nix` writes nix.conf with
#
#     substituters = https://cache.nixos.org $EXTRA_SUBSTITUTERS
#     netrc-file   = $HOME/.config/nix/netrc
#
# and every caller in this org puts its PRIVATE Attic cache in
# `$EXTRA_SUBSTITUTERS`. Until this script existed the netrc it then wrote
# carried ONE entry — `machine github.com` — so nix had no credential for the
# very cache it had just been told to use. `GET <cache>/nix-cache-info` answers
# 401, nix disables that substituter for `narinfo-cache-negative-ttl` seconds
# and retries forever, and everything not on cache.nixos.org is built FROM
# SOURCE. On the bare-metal runners a warm /nix/store hides it; on the
# ephemeral ones, whose store starts empty, it is the difference between a
# substituted closure and a full toolchain build — which is how it was found,
# as a cascade of unrelated-looking source builds failing on third-party
# fetches.
#
# The action already accepted `attic-token`, and already used it — in the
# "Start Attic watch-store" step, which runs `attic login`. That configures the
# Attic CLI for PUSHING and writes nothing nix reads. Nix reads netrc. So the
# token was present and inert for reading, and this file is the missing line.
#
# THE FORMAT IS ATTIC'S OWN, NOT AN INVENTION
# -------------------------------------------
# `attic use <cache>` is the supported way to point nix at an Attic cache, and
# what it writes into netrc is (client/src/nix_netrc.rs, client/src/command/use.rs):
#
#     machine <host of the substituter URL>
#     password <token>
#
# — the URL's HOST only, with no port, no path and no `login` line at all. An
# Attic substituter URL IS `<endpoint>/<cache>`, so the host this script takes
# from `attic-endpoint` and the host attic takes from the substituter are the
# same string by construction, and `attic-endpoint` is the one of the two that
# this action is actually given. It is also the server `attic login` is pointed
# at below, which is what makes it the token's audience rather than a guess.
# This

# script writes the same three tokens on one line, which is the same document:
# netrc is whitespace-separated and a newline is just whitespace. It does NOT
# run `attic use`, because that command also rewrites `substituters` and
# `trusted-public-keys` in nix.conf, and those are the caller's to state.
#
# HOST GRANULARITY, DELIBERATELY
# ------------------------------
# netrc has no path granularity — `machine <host>` is the finest scope the
# format has, as the note in action.yml beside the github.com entry already
# says. So a token written here is presented to every request nix makes to that
# host. That is the same grain the Attic client itself uses, and the host in
# question is the org's own cache endpoint, which issued the token.
#
# Environment:
#   GH_TOKEN           (required) the GitHub token, for `machine github.com`.
#   ATTIC_TOKEN        (optional) when non-empty, an entry for the Attic host
#                      is appended. When empty NOTHING is appended and the file
#                      is byte-for-byte what this action wrote before.
#   ATTIC_ENDPOINT     the Attic server URL. Required when ATTIC_TOKEN is set.
#   EXTRA_SUBSTITUTERS (optional) only to report the anonymous-read condition.
#   NETRC_PATH         (optional) where to write. Default
#                      "$HOME/.config/nix/netrc", which is what nix.conf's
#                      `netrc-file` names.
#
# Exit codes:
#   0  written
#   1  ATTIC_TOKEN was supplied but no entry could be written for it. Never
#      silent: a token that cannot be filed is the defect this script fixes,
#      one level up.
#   2  usage: GH_TOKEN missing, or NETRC_PATH unusable.
#
# Contract suite: ./nix-netrc-test.sh
set -euo pipefail

ME="write-nix-netrc"

GH_TOKEN="${GH_TOKEN-}"
ATTIC_TOKEN="${ATTIC_TOKEN-}"
ATTIC_ENDPOINT="${ATTIC_ENDPOINT-}"
EXTRA_SUBSTITUTERS="${EXTRA_SUBSTITUTERS-}"
NETRC_PATH="${NETRC_PATH:-${HOME}/.config/nix/netrc}"

die() { # <exit-code> <message...>
	local rc="$1"
	shift
	echo "$ME: $*" >&2
	exit "$rc"
}

[ -n "$GH_TOKEN" ] || die 2 "GH_TOKEN is empty. nix fetches every private flake input in this org through this file; writing it without the github.com credential would unauthenticate all of them."

# ---------------------------------------------------------------------------
# attic_host_of <url> -> ATTIC_HOST
#
# The host of an absolute URL: no scheme, no userinfo, no port, no path. That
# is what `attic use` files its entry under (`Url::host()`), and it is what
# curl — the client nix hands this file to via CURLOPT_NETRC_FILE — matches
# `machine` against. curl compares the HOSTNAME it parsed out of the request
# URL, so an entry carrying a port or a path matches nothing at all and fails
# exactly like having no entry.
#
# Every rejection below is a REFUSAL rather than a guess. A credential filed
# under the wrong machine name is indistinguishable, from inside a job, from
# the missing-credential defect this script exists to fix.
# ---------------------------------------------------------------------------
attic_host_of() { # <url>
	local u="$1" authority

	case "$u" in
	*://*) ;;
	*) die 1 "attic-endpoint must be an absolute URL with a scheme (e.g. https://cache.example.com/); got '$u'. Without one, whether the text is a host or a path is a guess." ;;
	esac

	authority="${u#*://}"
	authority="${authority%%/*}" # path
	authority="${authority%%\?*}" # query, if an endpoint ever carries one
	authority="${authority%%#*}"  # fragment, likewise
	authority="${authority##*@}"  # userinfo

	case "$authority" in
	"["*)
		die 1 "attic-endpoint '$u' names an IPv6 literal. curl and netrc disagree about whether the brackets belong in a 'machine' name, and filing this credential under the wrong spelling would be silently indistinguishable from not filing it at all. Give the cache a DNS name."
		;;
	esac

	authority="${authority%%:*}" # port

	case "$authority" in
	"") die 1 "attic-endpoint '$u' has no host component." ;;
	esac
	case "$authority" in
	*[!0-9A-Za-z._-]*)
		die 1 "the host of attic-endpoint '$u' contains a character that is not [0-9A-Za-z._-]. netrc is whitespace-separated and has no quoting, so such a name cannot be written as a 'machine' token."
		;;
	esac

	ATTIC_HOST="$authority"
}

# ---------------------------------------------------------------------------
# The file. `umask 077` is not cosmetic: on the self-hosted runners in this org
# $HOME is reused between jobs, so this file is readable by whatever runs next
# unless it is mode 600.
#
# BUILT BESIDE THE TARGET AND RENAMED OVER IT, which is not tidiness either.
# `umask` applies to file CREATION, so `> "$NETRC_PATH"` onto a path a previous
# job already created keeps THAT file's mode: a 0644 netrc left behind by
# anything at all silently becomes a 0644 netrc holding this job's tokens, on
# exactly the runners the umask was written for. A fresh temp file is created
# under the umask, gets the tokens, and `mv` carries its 0600 over the old
# path. The rename is also atomic, so no reader ever sees a half-written netrc,
# and the replacement is total — a stale entry cannot survive into this job.
# ---------------------------------------------------------------------------
umask 077
netrc_dir="$(dirname "$NETRC_PATH")"
mkdir -p "$netrc_dir" || die 2 "cannot create $netrc_dir"

NETRC_TMP="${NETRC_PATH}.tmp.$$"
trap 'rm -f "$NETRC_TMP"' EXIT
: >"$NETRC_TMP" || die 2 "cannot write next to $NETRC_PATH"

# Nix's internal git fetcher needs this for `?submodules=1` flake references,
# which clone via git rather than through the tarball fetcher.
printf 'machine github.com login x-access-token password %s\n' "$GH_TOKEN" >"$NETRC_TMP"

HOSTS="github.com"

if [ -n "$ATTIC_TOKEN" ]; then
	case "$ATTIC_TOKEN" in
	*[[:space:]]*)
		# Deliberately never echoes the value. The overwhelmingly likely cause
		# is a trailing newline in the stored secret, and silently trimming a
		# credential is worse than refusing it: it would write a DIFFERENT
		# token than the one the owner set and report success.
		die 1 "attic-token contains whitespace. netrc has no quoting, so the password token ends at the first space and the entry would carry a truncated credential. Re-add the secret without a trailing newline."
		;;
	esac

	[ -n "$ATTIC_ENDPOINT" ] || die 1 "attic-token was supplied but attic-endpoint is empty, so there is no host to file the credential under. nix would go on reading the private cache anonymously, which is the exact defect this entry exists to fix."

	attic_host_of "$ATTIC_ENDPOINT"

	# `machine github.com` above is a separate entry and keeps its own
	# credential: netrc entries do not inherit from one another, so the GitHub
	# token is never presented to the cache and the cache token is never
	# presented to github.com. The suite observes both directions on the wire.
	#
	# No `login`: `attic use` writes none, and curl sends Basic auth with an
	# empty username, which is what the Attic server expects.
	printf 'machine %s password %s\n' "$ATTIC_HOST" "$ATTIC_TOKEN" >>"$NETRC_TMP"
	HOSTS="$HOSTS, $ATTIC_HOST"
fi

mv -f "$NETRC_TMP" "$NETRC_PATH" || die 2 "cannot install $NETRC_PATH"
trap - EXIT

echo "$ME: wrote $NETRC_PATH with credentials for: $HOSTS"

if [ -z "$ATTIC_TOKEN" ] && [ -n "$EXTRA_SUBSTITUTERS" ]; then
	# Named, not warned. This is true in the majority of jobs in this org today
	# and an annotation on every one of them would be noise; a line in the log
	# of the job that pays for it is what was missing when a fleet-wide
	# source-build cascade had to be diagnosed from crate fetch errors.
	echo "$ME: NOTE: extra substituter(s) were declared ($EXTRA_SUBSTITUTERS) but no attic-token was supplied, so nix will read them ANONYMOUSLY. A private cache answers 401 to that, and nix then disables it and builds from source. Pass attic-token (and attic-cache) to make the cache readable."
fi
