#!/usr/bin/env bash
#
# assert-no-persisted-credential.sh — fail if the checkout this runs inside
# carries a credential in its local git configuration.
#
# WHY THIS EXISTS
# ---------------
# `actions/checkout` defaults to `persist-credentials: true` and writes
#
#     http.https://github.com/.extraheader = AUTHORIZATION: basic <workflow token>
#
# into the checkout's LOCAL `.git/config`. That is a catch-all: git matches
# `http.<url>.*` by scheme + host + port + slash-delimited path prefix, and
# `https://github.com/` is a prefix of every github.com URL. So any `git`
# command a job runs with its cwd inside the checkout presents the workflow
# token to every github.com URL it touches — including third-party ones — and
# on a runner that reuses workspaces the file outlives the job that minted it.
#
# The jobs in `test.yml` set `persist-credentials: false` because they perform
# no git operation after the checkout. This script is the executable form of
# that claim: it asserts the credential is actually absent rather than trusting
# the input to keep meaning what it means today.
#
# WHAT IT DOES NOT DO
# -------------------
# It never prints a credential. Every check reports only whether a key is set
# and, for URL rewrites, only the configuration KEY — which is why the
# `x-access-token` test below matches on the key name (`git config --name-only`)
# and never reads a value.
#
# Run: bash .github/assert-no-persisted-credential.sh   (from a checkout root)
set -uo pipefail

FAIL=0
ok() { echo "ok   $1"; }
bad() {
	FAIL=1
	echo "FAIL $1"
	[[ -n ${2:-} ]] && echo "     $2"
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	echo "assert-no-persisted-credential: not a git repository; nothing to assert" >&2
	exit 2
fi

# 1. The `actions/checkout` header itself. `--get-all` exits 1 when the key is
#    unset, which is the passing case; count the lines rather than reading any.
n="$({ git config --local --get-all 'http.https://github.com/.extraheader' 2>/dev/null || true; } | grep -c . || true)"
if [[ $n -eq 0 ]]; then
	ok "no http.https://github.com/.extraheader in .git/config"
else
	bad "the checkout persisted a catch-all Authorization header" \
		"$n value(s) set for http.https://github.com/.extraheader; set persist-credentials: false"
fi

# 2. The same shape written under any other URL prefix — a narrower scope is
#    still a persisted credential, so report it, and report only the key.
while IFS= read -r key; do
	[[ -z $key ]] && continue
	bad "a persisted extraheader is configured" "key: $key"
done < <({ git config --local --name-only --get-regexp '^http\..*\.extraheader$' 2>/dev/null || true; })

# 3. A credential-bearing URL rewrite, the other way the same thing gets stored.
while IFS= read -r key; do
	[[ -z $key ]] && continue
	case "$key" in
	*x-access-token*) bad "a credential-bearing url rewrite is configured" "key: ${key//x-access-token*@/x-access-token:***@}" ;;
	esac
done < <({ git config --local --name-only --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true; })

if [[ $FAIL -eq 0 ]]; then
	echo "assert-no-persisted-credential: checkout carries no stored credential."
else
	echo "assert-no-persisted-credential: STORED CREDENTIAL PRESENT." >&2
fi
exit "$FAIL"
