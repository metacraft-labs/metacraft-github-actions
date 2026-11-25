#!/bin/sh
#
# git-credential-job-token.sh -- the Git credential helper that hands a CI job's
# current GitHub token to Git at the moment Git asks for one.
#
# Usage (Git runs it; nothing else should):
#
#   git-credential-job-token.sh <credential-dir> <get|store|erase>
#
# Git calls a configured `credential.<url>.helper` with the operation as its
# last argument and the request on standard input, as `key=value` lines ended
# by a blank line or end of input. A `get` answers with `key=value` lines on
# standard output. The protocol is documented in
# https://git-scm.com/docs/git-credential#IOFMT and the helper mechanism in
# https://git-scm.com/docs/gitcredentials#_custom_helpers.
#
# WHY A HELPER, AND WHY IT READS A FILE
# -------------------------------------
# A GitHub App installation token lives one hour. A credential frozen into the
# job's environment (an `http.<url>.extraHeader` in `GIT_CONFIG_*`) cannot be
# changed once a step has started, so a Git operation more than an hour after
# the mint failed with `could not read Username`. Git runs this helper anew for
# every request that needs a credential, and the helper reads the token from
# `<credential-dir>/git-token` each time. Whatever rotates the job's
# credential (the broker in refresh-build-auth/job-credentials.cjs,
# refresh-build-auth, setup-nix) replaces that file atomically (write, then
# rename), so a Git process started before a rotation, or one a long-lived
# daemon spawns afterwards, is handed the new token.
#
# WHAT IT ANSWERS
# ---------------
#   get    `username=x-access-token` and `password=<token>`, the form GitHub
#          accepts for an App installation token over HTTPS. Nothing at all
#          when the directory or the file is missing, or the file holds no
#          usable token: on a persistent runner a stale reference then means
#          no credential, not a dead one, and Git reports the failure itself.
#   store  Ignored. The job's token file is not Git's to write.
#   erase  Ignored. Git sends `erase` after a 401 with the credential it used;
#          honouring it would delete the job's credential for every later
#          process because one request was refused.
#
# Which URLs it answers for is decided by Git, not here: the helper is
# configured as `credential.<scope>.helper` for each covered URL prefix (see
# scoped-git-auth.sh), so Git never calls it for any other URL.
#
# The token is written to standard output in answer to `get` and nowhere else:
# not to standard error, not to a log, not into a file.
#
# PORTABILITY. POSIX sh and shell builtins only, written for macOS's /bin/sh
# (bash 3.2 in POSIX mode), dash, bash, and the MSYS sh that Git for Windows
# uses for helpers (the last not yet measured), and it needs nothing from
# PATH: the self-hosted macOS runners have been seen without sed, and a helper
# that died for want of a tool would unauthenticate every private fetch in the
# job.

dir=${1-}
operation=${2-}

# Read the whole request, whatever the operation. Git writes it before it
# reads the answer, and leaving it unread would make that write fail on a
# closed pipe. The attributes themselves are not needed: Git has already
# matched the URL against the helper's scope.
while IFS= read -r _line; do :; done

[ "$operation" = get ] || exit 0
[ -n "$dir" ] || exit 0
file=$dir/git-token
[ -f "$file" ] || exit 0

token=
# The file can be renamed over or removed between the test above and this
# read; either way the read sees a whole token or nothing, and the shell's own
# message about a vanished file is not Git's business.
{ IFS= read -r token <"$file"; } 2>/dev/null || :

case $token in
'' | *[[:space:]]*) exit 0 ;;
esac

printf 'username=x-access-token\npassword=%s\n' "$token"
