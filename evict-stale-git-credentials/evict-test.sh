#!/usr/bin/env bash
# evict-test.sh -- evict.sh removes the credential-bearing keys of a reused
# runner's ~/.gitconfig, keeps everything else, and does it with no grep, sed
# or awk on PATH (the nix-darwin runners' raw-step PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
ok() { echo "  ok   $*"; }
fail() {
  echo "  FAIL $*"
  failures=$((failures + 1))
}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
home="$work/home"
mkdir -p "$home" "$work/bin"
git config --file "$home/.gitconfig" user.name runner
git config --file "$home/.gitconfig" http.https://github.com/metacraft-labs/.extraHeader "AUTHORIZATION: basic STALE"
git config --file "$home/.gitconfig" url."https://x-access-token:STALE@github.com/".insteadOf "https://github.com/"
git config --file "$home/.gitconfig" url."https://github.com/".insteadOf "git@github.com:"

# Only bash and git, as a raw nix-darwin step has.
ln -s "$(command -v bash)" "$work/bin/bash"
ln -s "$(command -v git)" "$work/bin/git"
out="$(HOME="$home" PATH="$work/bin" RUNNER_NAME=test bash "$here/evict.sh" 2>&1)" || fail "evict.sh exited non-zero: $out"

if git config --file "$home/.gitconfig" --get-urlmatch http.extraheader https://github.com/metacraft-labs/codetracer >/dev/null; then
  fail "an extraheader still applies to github.com/metacraft-labs after eviction"
else
  ok "no extraheader applies to github.com/metacraft-labs any more (mode 1's stale key is gone)"
fi
if git config --file "$home/.gitconfig" --list | grep -q 'x-access-token'; then
  fail "a url.*x-access-token* rewrite survived"
else
  ok "the x-access-token rewrite is gone"
fi
if [ "$(git config --file "$home/.gitconfig" user.name)" = runner ] &&
  git config --file "$home/.gitconfig" --get url.https://github.com/.insteadOf >/dev/null; then
  ok "the credential-free keys (user.name, the ssh-to-https rewrite) are kept"
else
  fail "a credential-free key was removed"
fi
if grep -q 'removed 2 credential-bearing key(s); 0 still present' <<<"$out"; then
  ok "it reports what it removed and that none survived, with no grep or sed on PATH"
else
  fail "its report is wrong: $out"
fi
out2="$(HOME="$work/nohome" PATH="$work/bin" bash "$here/evict.sh" 2>&1)" || fail "evict.sh failed on a host with no ~/.gitconfig"
grep -q 'removed 0 (no ' <<<"$out2" && ok "a host with no ~/.gitconfig is a clean no-op" || fail "no-gitconfig case: $out2"

echo
[ "$failures" -eq 0 ] && echo "evict-stale-git-credentials: all checks passed" || {
  echo "$failures failure(s)"
  exit 1
}
