# shellcheck shell=bash
#
# flake-lock-revisions.sh -- read the git revisions a Nix `flake.lock` pins for
# its root inputs, using nothing but bash builtins. Sourced by
# `provision-reprobuild-siblings.sh`; it defines functions and runs nothing.
#
# WHY BASH BUILTINS AND NOT python3, jq OR nix
# --------------------------------------------
# The provisioning step runs before any toolchain is set up, in a `run:` step
# whose PATH on the self-hosted macOS runners is a Nix profile carrying bash
# and git but not python3, coreutils, sed, awk or grep, and whose bash may be
# 3.2. This file used to be a python3 heredoc, and that runner refused every
# source build with "needs a working python3 (or python) on PATH".
#
#   - python3 / jq are not on that PATH, and Windows can resolve `python3` to
#     the Microsoft Store stub, which exits 9009.
#   - `nix eval` is not available here either: `setup-reprobuild` installs Nix
#     in a LATER step ("Install Nix (Linux/macOS, to build repro)"), and the
#     Windows path never installs it at all.
#
# So the lock is tokenized here. Bash 3.2 compatible: no associative arrays,
# no `${var,,}`, no `mapfile`.
#
# THE FORMAT
# ----------
# https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake#lock-files
# A lock is a JSON object `{"nodes": {<name>: <node>}, "root": <name>, ...}`.
# The root node's `inputs` maps each input alias to a node name (a string), or
# to a `follows` path (an array, skipped here). A node's `locked` object holds
# the source coordinates: `type`, plus `owner`/`repo` for the forge types, or
# `url` for `git`, and `rev`.
#
# The tokenizer splits the file on `"` with `read -d`, so segments alternate
# between text outside a string and a string's contents; it never depends on
# Nix's pretty-printing. A segment inside a string that ends in an odd number
# of backslashes ended on an escaped quote and continues. String contents are
# kept in their escaped form: the fields read here (hex revisions, owners,
# repository names, URLs, node names) never need unescaping, and a node name
# is compared escaped-to-escaped.

# `flake_lock_lowercase <text>` -- print <text> with ASCII A-Z lower-cased,
# without `tr` and without bash 4's `${var,,}`.
flake_lock_lowercase() {
  local text="$1" out="" c prefix i
  local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lower="abcdefghijklmnopqrstuvwxyz"
  for ((i = 0; i < ${#text}; i++)); do
    c="${text:i:1}"
    case "${c}" in
    [ABCDEFGHIJKLMNOPQRSTUVWXYZ])
      prefix="${upper%%"${c}"*}"
      c="${lower:${#prefix}:1}"
      ;;
    esac
    out+="${c}"
  done
  printf '%s' "${out}"
}

# `flake_lock_revisions <flake.lock>` -- print one `<repository> <owner> <rev>`
# line per distinct (repository, owner, revision) that a ROOT input locks to a
# git forge source (`github`, `gitlab`, `sourcehut`) or a `git` URL. The
# repository and owner are lower-cased; the revision is a full 40-hex SHA.
# Inputs of other kinds, `follows` entries and non-SHA revisions are skipped.
# Inputs are reported by repository coordinates, never by input alias.
#
# Returns 1, with the reason on stderr, when the file cannot be read or is not
# a well-formed lock; nothing is printed then.
flake_lock_revisions() {
  local file="$1"
  if [ ! -r "${file}" ]; then
    echo "unreadable flake.lock: cannot read ${file}" >&2
    return 1
  fi

  # Parser state. `kinds[d]` is `o` (object) or `a` (array) for the container
  # at depth d (1 = the top-level object); `keys[d]` is the key that container
  # sits under in its parent. `key` is the current object key, `expect` says
  # whether the next string in an object is a key or a value.
  local -a kinds=() keys=()
  local depth=0 key="" expect="key" inside=0 seg="" str="" pending="" more=1
  local trailing
  # Results: the root node's name, every `nodes/<node>/inputs/<alias>` whose
  # value is a node name (a string; `follows` arrays are skipped), and every
  # node's `locked` fields.
  local root_name="" root_seen=0
  local -a in_owner_node=() in_target=()
  local -a lk_node=() lk_type=() lk_owner=() lk_repo=() lk_url=() lk_rev=()
  local cur_type="" cur_owner="" cur_repo="" cur_url="" cur_rev=""

  # Called for each complete string token.
  _flake_lock_string() {
    local s="$1"
    if [ "${depth}" -eq 0 ]; then
      return 1
    fi
    if [ "${kinds[depth]}" = o ] && [ "${expect}" = key ]; then
      key="${s}"
      expect="colon"
      return 0
    fi
    if [ "${kinds[depth]}" = o ] && [ "${expect}" != value ]; then
      return 1
    fi
    # A string value.
    if [ "${depth}" -eq 1 ] && [ "${key}" = root ]; then
      root_name="${s}"
      root_seen=1
    elif [ "${depth}" -eq 4 ] && [ "${kinds[4]}" = o ] && [ "${keys[2]}" = nodes ] \
      && [ "${keys[4]}" = inputs ]; then
      in_owner_node+=("${_node}")
      in_target+=("${s}")
    elif [ "${depth}" -eq 4 ] && [ "${kinds[4]}" = o ] && [ "${keys[2]}" = nodes ] \
      && [ "${keys[4]}" = locked ]; then
      case "${key}" in
      type) cur_type="${s}" ;;
      owner) cur_owner="${s}" ;;
      repo) cur_repo="${s}" ;;
      url) cur_url="${s}" ;;
      rev) cur_rev="${s}" ;;
      esac
    fi
    [ "${kinds[depth]}" = o ] && expect="comma"
    return 0
  }

  # `_node` is the node being read: the key of the depth-3 object under
  # `nodes`. Depths: 1 the lock, 2 `nodes`, 3 a node, 4 its `inputs`/`locked`.
  local _node=""

  # `_flake_lock_outside <text>` -- structural characters between strings.
  _flake_lock_outside() {
    local text="$1" n=${#1} j ch scalar=0
    for ((j = 0; j < n; j++)); do
      ch="${text:j:1}"
      case "${ch}" in
      ' ' | $'\t' | $'\n' | $'\r')
        scalar=0
        ;;
      '{' | '[')
        if [ "${depth}" -gt 0 ] && [ "${kinds[depth]}" = o ] && [ "${expect}" != value ]; then
          return 1
        fi
        depth=$((depth + 1))
        if [ "${depth}" -eq 1 ]; then
          keys[depth]=""
        elif [ "${kinds[depth - 1]}" = o ]; then
          keys[depth]="${key}"
        else
          keys[depth]="#"
        fi
        if [ "${ch}" = '{' ]; then kinds[depth]=o; else kinds[depth]=a; fi
        if [ "${depth}" -eq 3 ] && [ "${keys[2]}" = nodes ]; then _node="${keys[3]}"; fi
        expect="key"
        key=""
        scalar=0
        ;;
      '}' | ']')
        if [ "${depth}" -eq 0 ]; then return 1; fi
        if [ "${ch}" = '}' ] && [ "${kinds[depth]}" != o ]; then return 1; fi
        if [ "${ch}" = ']' ] && [ "${kinds[depth]}" != a ]; then return 1; fi
        if [ "${kinds[depth]}" = o ] && { [ "${expect}" = colon ] || [ "${expect}" = value ]; }; then
          return 1
        fi
        if [ "${depth}" -eq 4 ] && [ "${keys[2]}" = nodes ] && [ "${keys[4]}" = locked ]; then
          lk_node+=("${_node}")
          lk_type+=("${cur_type}")
          lk_owner+=("${cur_owner}")
          lk_repo+=("${cur_repo}")
          lk_url+=("${cur_url}")
          lk_rev+=("${cur_rev}")
          cur_type="" cur_owner="" cur_repo="" cur_url="" cur_rev=""
        fi
        unset "kinds[depth]" "keys[depth]"
        depth=$((depth - 1))
        if [ "${depth}" -gt 0 ] && [ "${kinds[depth]}" = o ]; then expect="comma"; fi
        scalar=0
        ;;
      ':')
        if [ "${depth}" -eq 0 ] || [ "${kinds[depth]}" != o ] || [ "${expect}" != colon ]; then
          return 1
        fi
        expect="value"
        ;;
      ',')
        if [ "${depth}" -eq 0 ]; then return 1; fi
        if [ "${kinds[depth]}" = o ]; then
          [ "${expect}" = comma ] || return 1
          expect="key"
        fi
        scalar=0
        ;;
      [-+.0-9eEtrufalsn])
        # A number, true, false or null: a value that is never read here.
        if [ "${depth}" -eq 0 ]; then return 1; fi
        if [ "${kinds[depth]}" = o ]; then
          if [ "${scalar}" = 0 ] && [ "${expect}" != value ]; then return 1; fi
          expect="comma"
        fi
        scalar=1
        ;;
      *)
        return 1
        ;;
      esac
    done
    return 0
  }

  # The tokenizer: alternate outside / inside on every unescaped quote.
  while [ "${more}" = 1 ]; do
    if ! IFS= read -r -d '"' seg; then
      more=0
    fi
    if [ "${inside}" = 0 ]; then
      if ! _flake_lock_outside "${seg}"; then
        echo "unreadable flake.lock: ${file} is not well-formed JSON" >&2
        return 1
      fi
      [ "${more}" = 1 ] && inside=1
      continue
    fi
    if [ "${more}" = 0 ]; then
      echo "unreadable flake.lock: ${file} ends inside a string" >&2
      return 1
    fi
    trailing="${seg##*[!\\]}"
    if [ $((${#trailing} % 2)) -eq 1 ]; then
      pending+="${seg}\""
      continue
    fi
    str="${pending}${seg}"
    pending=""
    inside=0
    if ! _flake_lock_string "${str}"; then
      echo "unreadable flake.lock: ${file} is not well-formed JSON" >&2
      return 1
    fi
  done <"${file}"

  if [ "${depth}" -ne 0 ] || [ "${root_seen}" != 1 ]; then
    echo "unreadable flake.lock: ${file} has no top-level \"root\" or is truncated" >&2
    return 1
  fi

  local seen=$'\n' line n k owner repo rev url rest
  for ((n = 0; n < ${#in_target[@]}; n++)); do
    [ "${in_owner_node[n]}" = "${root_name}" ] || continue
    for ((k = 0; k < ${#lk_node[@]}; k++)); do
      [ "${lk_node[k]}" = "${in_target[n]}" ] || continue
      rev="${lk_rev[k]}"
      case "${lk_type[k]}" in
      github | gitlab | sourcehut)
        owner="${lk_owner[k]}"
        repo="${lk_repo[k]}"
        ;;
      git)
        url="${lk_url[k]}"
        while [ "${url%/}" != "${url}" ]; do url="${url%/}"; done
        repo="${url##*/}"
        rest="${url%/*}"
        owner=""
        [ "${rest}" != "${url}" ] && owner="${rest##*/}"
        repo="${repo%.git}"
        ;;
      *)
        continue
        ;;
      esac
      [ -n "${owner}" ] && [ -n "${repo}" ] || continue
      [[ ${rev} =~ ^[0-9a-f]{40}$ ]] || continue
      line="$(flake_lock_lowercase "${repo}") $(flake_lock_lowercase "${owner}") ${rev}"
      case "${seen}" in *$'\n'"${line}"$'\n'*) continue ;; esac
      seen+="${line}"$'\n'
      printf '%s\n' "${line}"
    done
  done
  return 0
}
