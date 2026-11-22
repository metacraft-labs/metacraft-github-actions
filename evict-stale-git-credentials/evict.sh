#!/usr/bin/env bash
# Evict credential-bearing keys from the runner's persistent ~/.gitconfig.
# See action.yml for why, and why it runs before any checkout.
set -uo pipefail
cfg="$HOME/.gitconfig"
echo "cred-evict: runner=${RUNNER_NAME:-?} home=$HOME"
if [ ! -f "$cfg" ]; then
  echo "cred-evict: removed 0 (no $cfg on this runner - nothing reusable to poison)"
  exit 0
fi
echo "cred-evict: inspecting $cfg"
removed=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  case "$key" in
    http.*.extraheader|http.*.extraHeader) ;;
    url.*x-access-token*) ;;
    *) continue ;;
  esac
  echo "cred-evict:   removing '$key' (value withheld)"
  git config --file "$cfg" --unset-all "$key" 2>/dev/null || true
  git config --file "$cfg" --remove-section "${key%.*}" 2>/dev/null || true
  removed=$((removed + 1))
done < <(git config --file "$cfg" --list --name-only 2>/dev/null || true)
# Recount in PURE BASH. `grep` and `sed` are NOT on PATH in a raw
# `run:` step on these nix-darwin runners -- the first version of
# this step used `grep -ciE` here, grep exited 127, `|| true`
# swallowed it, and the step printed "removed 1 key(s);  still
# present" with an EMPTY count. That is precisely the failure this
# step is supposed to be immune to: a verification that silently
# verifies nothing and still reads like a pass. No external
# commands in the check.
left=0
while IFS= read -r k; do
  case "$k" in
    *extraheader*|*extraHeader*|*x-access-token*) left=$((left + 1)) ;;
  esac
done < <(git config --file "$cfg" --list --name-only 2>/dev/null || true)
echo "cred-evict: removed $removed credential-bearing key(s); $left still present"
if [ "$removed" -eq 0 ]; then
  echo "cred-evict: NOTHING FOUND - this host was already clean, mode 1 did not apply here"
fi
if [ "$left" -ne 0 ]; then
  echo "cred-evict: WARNING $left credential-shaped key(s) SURVIVED the sweep"
fi
echo "cred-evict: keys remaining in $cfg:"
while IFS= read -r k; do echo "  $k"; done < <(git config --file "$cfg" --list --name-only 2>/dev/null || true)
