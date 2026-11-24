#!/usr/bin/env bash
# Move one tooling pin: rewrite `rev` and `narHash` in pins/<tool>.json from a
# fresh fetch of <rev>, and change nothing else in the file.
#
# usage: tools/update-pin.sh <tool> <full 40-hex rev>
#
# The hash comes from `nix flake prefetch`, never from the caller, so a typed
# hash cannot disagree with the tree. Fetching a private repository needs the
# caller's Nix to hold a token that can read it; this script never prints one.
# A bump is a deploy for every consumer that follows the pin: put the reason
# (the release or milestone) in the commit message, not in the file.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: tools/update-pin.sh <tool> <full 40-hex rev>" >&2
  exit 2
fi
tool=$1
rev=$2
case "$tool" in
  *[!a-z0-9-]* | "" | -*) echo "error: invalid tool name: $tool" >&2; exit 2 ;;
esac
if ! printf '%s' "$rev" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "error: rev must be a full lowercase 40-hex commit SHA" >&2
  exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
file=$root/pins/$tool.json
[ -f "$file" ] || { echo "error: no such pin: $file" >&2; exit 2; }

owner=$(jq -er .owner "$file")
repo=$(jq -er .repo "$file")
hash=$(nix flake prefetch --json "github:$owner/$repo/$rev" | jq -er .hash)

tmp=$(mktemp "$file.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq --arg rev "$rev" --arg hash "$hash" '.rev = $rev | .narHash = $hash' "$file" > "$tmp"
mv -- "$tmp" "$file"
trap - EXIT
python3 -I "$root/tools/check-pins.py" --pins-dir "$root/pins"
echo "pin $tool -> $rev ($hash)"
