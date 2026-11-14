#!/usr/bin/env bash
#
# scoped-git-auth.sh -- the one place in this repo that decides how a CI GitHub
# token is handed to git. SOURCE it; it defines functions and sets nothing on
# its own.
#
# WHY THIS IS SHARED
# ------------------
# `setup-nix` used to authenticate git with a global, URL-embedded, catch-all
# rewrite. That was replaced by an owner-scoped `http.<url>.extraHeader` carried
# in process-scoped git configuration (see setup-nix/configure-git-auth.sh for
# the full argument). The identical shape survived in `clone-siblings` and
# `clone-repo`, which build their clone URLs as
#
#     https://x-access-token:<token>@github.com/<owner>/<repo>.git
#
# and, for submodules, wrote that same rewrite into each clone's `.git/config`.
# That is the same three defects at a different scope:
#
#   1. THE TOKEN ENDS UP IN URLs. It reaches `git-remote-https`'s argv (readable
#      in /proc on a shared runner), is written verbatim into the `.git/config`
#      of every clone and of every submodule the rewrite touched, and is echoed
#      by git's own "unable to access 'https://x-access-token:...@github.com/...'"
#      failure text.
#   2. PERSISTENCE. Those `.git/config` copies outlive the step. Sibling clones
#      sit next to the workspace, get archived as artifacts, and on the
#      self-hosted runners in this org survive into the next job.
#   3. BREADTH. `insteadOf "https://github.com/"` in a clone's `.git/config`
#      catches every github.com URL that clone ever fetches -- including its
#      third-party submodules and anything a build tool resolves from inside it.
#
# Keeping the two copies in sync by hand is how the `setup-nix` fix came to be
# only two-thirds of a fix. So the scope lives here, once, and every caller --
# `setup-nix`, `clone-siblings`, `clone-repo` -- derives it from this file.
#
# WHAT A CALLER GETS
# ------------------
#   scoped_git_auth_build   Derive the scope + credential. Sets the array
#                           SCOPED_GIT_AUTH_PAIRS (KEY VALUE KEY VALUE ...) and
#                           SCOPED_GIT_AUTH_SCOPES (the URL prefixes covered).
#                           First evicts stale credential headers from the
#                           runner's persistent global git config files (see
#                           scoped_git_auth_evict_stale_home_headers): that is
#                           its only effect outside this shell.
#   scoped_git_auth_export  Export SCOPED_GIT_AUTH_PAIRS into THIS process as
#                           GIT_CONFIG_COUNT/KEY_n/VALUE_n, appending to whatever
#                           was already there. Nothing touches disk; child
#                           processes (including `git submodule update
#                           --recursive`) inherit it, and nothing else does.
#   scoped_git_auth_emit    Print the same pairs as `KEY=VALUE` lines, for
#                           `$GITHUB_ENV` (job-scoped) -- what `setup-nix` needs,
#                           because the credential must outlive its own step.
#   scoped_git_auth_with_global  Run a command through a private temporary
#                           GIT_CONFIG_GLOBAL file, then remove it. This is for
#                           tools such as Repro that scrub numbered config.
#
# Environment read by scoped_git_auth_build:
#   GH_TOKEN                  The token. Empty/unset => no credential is derived
#                             at all (public clones still work); this is not an
#                             error, because several callers accept an empty
#                             token and clone only public repositories.
#   TOKEN_OWNERS              Whitespace/newline-separated GitHub owners the
#                             token is scoped to. Default: metacraft-labs.
#   EXTRA_TOKEN_URL_PREFIXES  Whitespace/newline-separated extra https URL
#                             prefixes to cover (e.g. one private repo in
#                             another org, authenticated by a per-repo secret).
#   SCOPED_GIT_AUTH_REWRITES  "1" to also emit the credential-FREE ssh->https
#                             `url.*.insteadOf` rewrites as process
#                             configuration. Callers that clone submodules want
#                             this; `setup-nix` does not, because it writes the
#                             same rewrites to `--global` for its own reasons.
#   GIT_AUTH_URL_BASE         The https base the scope is built on. Defaults to
#                             https://github.com/ and is overridden ONLY by the
#                             contract suite, which points it at a local
#                             authenticating git server so the assertions can
#                             observe the credential on the wire instead of
#                             asking git's matchers what they believe.
#
# THIS FILE NEVER PRINTS A CREDENTIAL, in any form: not the token, not the
# base64 blob, not a redacted prefix of either. The only place the derived blob
# is emitted is as the payload of a `::add-mask::` workflow command, which the
# runner consumes and replaces with `***`, and only when a caller asks for it.
#
# Contract suite: ./scoped-git-auth-test.sh

# `scoped_git_auth_b64 <ascii>` -- base64, via coreutils when it is there and in
# pure bash when it is not.
#
# The fallback is not defensive programming for its own sake: `clone-siblings`
# runs on hosts where the step's PATH is whatever the self-hosted runner's
# service environment provides, and this repo's own code already avoids
# awk/sed/grep/cat for that reason. A credential helper that silently produces
# an empty string because `base64` was missing would unauthenticate every
# private clone in the job while reporting success, so there is no acceptable
# failure mode here other than "always works".
#
# Input is ASCII (`x-access-token:<token>`); no binary handling is needed.
scoped_git_auth_b64() {
  local input="$1" out
  if command -v base64 >/dev/null 2>&1; then
    out="$(printf '%s' "$input" | base64)"
    # `base64` line-wraps at 76 columns; the encoding of a typical
    # `x-access-token:ghs_...` is right at that boundary, so this is load
    # bearing and not hygiene. Pure-bash strip: no `tr` either.
    out="${out//$'\n'/}"
    out="${out//$'\r'/}"
    printf '%s' "$out"
    return 0
  fi

  local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local i n c1 c2 c3 trip
  out=""
  for ((i = 0; i < ${#input}; i += 3)); do
    printf -v c1 '%d' "'${input:i:1}"
    c2=0
    c3=0
    n=1
    if [[ $((i + 1)) -lt ${#input} ]]; then
      printf -v c2 '%d' "'${input:i+1:1}"
      n=2
    fi
    if [[ $((i + 2)) -lt ${#input} ]]; then
      printf -v c3 '%d' "'${input:i+2:1}"
      n=3
    fi
    trip=$(((c1 << 16) | (c2 << 8) | c3))
    out+="${alphabet:$(((trip >> 18) & 63)):1}"
    out+="${alphabet:$(((trip >> 12) & 63)):1}"
    if [[ $n -ge 2 ]]; then out+="${alphabet:$(((trip >> 6) & 63)):1}"; else out+="="; fi
    if [[ $n -ge 3 ]]; then out+="${alphabet:$((trip & 63)):1}"; else out+="="; fi
  done
  printf '%s' "$out"
}

# `scoped_git_auth_evict_stale_home_headers <url-base>` -- remove every
# `http.<url>.extraHeader` whose <url> lies under <url-base> from the runner's
# PERSISTENT global git config files.
#
# WHY. Self-hosted runners in this org reuse their home directories across
# jobs, and some carry a `http.https://github.com/<owner>/.extraheader` in
# `~/.gitconfig` that an earlier job left there, holding that job's long-expired
# token. (This file never writes one there -- it hands the credential to git
# through process-scoped config -- but something on those runners does, and
# until that is found every entry point has to assume the poison can come
# back.) Git combines `http.<url>.*`
# from every config source, so that stale key is in effect for every job that
# runs on the host afterwards, in one of two ways:
#
#   * SAME URL as the scope built below: `extraHeader` is multi-valued, so git
#     sends BOTH headers and GitHub refuses the request with
#     `remote: Duplicate header: "Authorization"` / HTTP 400. Measured on
#     m3-mcl-006 (codetracer-snapshot-codecs job 131621245984,
#     codetracer-image-diff job 131623808481).
#   * A NARROWER URL: git uses the longest matching prefix only, so the stale
#     header REPLACES the fresh one, GitHub answers 401, and git reports
#     `could not read Username` (m3-mcl-005, job 131544370486).
#
# An extraheader in a home directory reused across jobs is never legitimate --
# it is a minted token outliving the job that minted it -- so it is removed
# whether or not this run installs a credential.
#
# WHICH FILES, AND WHY BY PATH. Git reads two global files, `~/.gitconfig` and
# `${XDG_CONFIG_HOME:-~/.config}/git/config`, and both are edited by path.
# `git config --global` writes to only ONE of them (and to `$GIT_CONFIG_GLOBAL`
# when that is set), so an `--unset --global` can report success while the
# offending file is left untouched. `$GIT_CONFIG_GLOBAL` itself is not edited:
# a file a caller named for this process is not the runner's persistent home.
#
# WHAT IS LEFT ALONE. Any key that is not an extraheader; any extraheader
# outside <url-base> (another host, or a bare `http.extraHeader`); and the
# section itself while anything else is still in it -- removing the whole
# `[http "<url>"]` section would also drop, say, its `sslVerify`.
#
# Key NAMES and counts are logged to stderr, and only when something was found.
# Values are never read into a variable, let alone printed: they hold tokens.
#
# Pure bash plus git. `grep`/`sed` are not on PATH in a raw `run:` step on the
# nix-darwin runners, and bash may be 3.2 there, hence `nocasematch` (3.1+)
# rather than `${var,,}` (4.0+).
scoped_git_auth_evict_stale_home_headers() {
  local base="${1%/}" home="${HOME:-}" cfg key k2 url sub other removed left seen
  local nocase_was_set=0
  [[ -n $home ]] || return 0
  shopt -q nocasematch && nocase_was_set=1
  shopt -s nocasematch
  for cfg in "$home/.gitconfig" "${XDG_CONFIG_HOME:-$home/.config}/git/config"; do
    [[ -f $cfg ]] || continue
    removed=0
    left=0
    seen=$'\n'
    # `--name-only` lists section and variable names lower-cased and the
    # subsection (the URL) as written; `--null` keeps a URL containing a
    # newline from splitting into two bogus names.
    while IFS= read -r -d '' key; do
      case "$key" in
      http.*.extraheader) ;;
      *) continue ;;
      esac
      url="${key#http.}"
      url="${url%.*}"
      # Host and scheme compare case-insensitively, as git's URL normaliser
      # does. `<base>` alone (no trailing slash) also matches every repo.
      case "$url" in
      "$base" | "$base"/*) ;;
      *) continue ;;
      esac
      # A multi-valued key is listed once per value; `--unset-all` took them all.
      case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
      seen+="$key"$'\n'
      if git config --file "$cfg" --unset-all "$key" 2>/dev/null; then
        removed=$((removed + 1))
        echo "scoped-git-auth: removed stale '$key' from $cfg (value withheld)" >&2
      else
        echo "scoped-git-auth: WARNING could not remove stale '$key' from $cfg" >&2
      fi
      # Drop the now-empty `[http "<url>"]` section, and only if it is empty.
      sub="http.${url}."
      other=0
      while IFS= read -r -d '' k2; do
        [[ ${k2:0:${#sub}} == "$sub" ]] && other=1 && break
      done < <(git config --file "$cfg" --list --name-only --null 2>/dev/null || true)
      [[ $other == 0 ]] &&
        { git config --file "$cfg" --remove-section "http.${url}" 2>/dev/null || true; }
    done < <(git config --file "$cfg" --list --name-only --null 2>/dev/null || true)
    [[ $removed == 0 ]] && continue
    # Recount from the file. An `--unset` that silently did nothing reads
    # exactly like one that worked, so the result is checked, not assumed.
    while IFS= read -r -d '' key; do
      case "$key" in
      http.*.extraheader) ;;
      *) continue ;;
      esac
      url="${key#http.}"
      url="${url%.*}"
      case "$url" in "$base" | "$base"/*) left=$((left + 1)) ;; esac
    done < <(git config --file "$cfg" --list --name-only --null 2>/dev/null || true)
    echo "scoped-git-auth: evicted ${removed} stale credential header(s) from $cfg; ${left} left" >&2
    [[ $left == 0 ]] ||
      echo "scoped-git-auth: WARNING ${left} stale credential header(s) survived in $cfg" >&2
  done
  [[ $nocase_was_set == 1 ]] || shopt -u nocasematch
  return 0
}

# `scoped_git_auth_build` -- derive the scope and the credential pairs.
scoped_git_auth_build() {
  local url_base="${GIT_AUTH_URL_BASE:-https://github.com/}"
  # The base is a TEST knob and is constrained to be one. Left unconstrained it
  # would be a way to point every clone -- and the credential scoped to it --
  # at an arbitrary host by setting one environment variable, which is a
  # strictly worse hole than the one this file exists to close. Anything that
  # is not github.com must be loopback.
  case "$url_base" in
  https://github.com/) ;;
  http://127.0.0.1:*/ | http://localhost:*/) ;;
  *)
    echo "scoped-git-auth: GIT_AUTH_URL_BASE must be https://github.com/ or a loopback address (got '$url_base')" >&2
    return 2
    ;;
  esac
  # Before anything that could hand git a credential -- and before the no-token
  # early return too, because a stale header breaks a public clone as surely as
  # a private one (GitHub answers a bad credential with 401 even on a public
  # repository). Every entry point in this repo that runs git with the job's
  # credential calls this function first, so this is the one place that covers
  # all of them; scoped_git_auth_with_global's private GIT_CONFIG_GLOBAL already
  # hides these files from its own command, and the eviction then simply
  # cleans the host for the next job.
  scoped_git_auth_evict_stale_home_headers "$url_base"
  local owners="${TOKEN_OWNERS:-metacraft-labs}"
  local extra="${EXTRA_TOKEN_URL_PREFIXES:-}"
  local _owner _prefix

  SCOPED_GIT_AUTH_SCOPES=()
  SCOPED_GIT_AUTH_PAIRS=()

  # The credential-free scheme rewrites. `.gitmodules` in this org's repos
  # spells submodule URLs in all three styles, and a rewrite is the only thing
  # that turns the ssh spellings into something an https credential can
  # authenticate. They carry no credential, so a caller that persists them
  # persists nothing sensitive.
  #
  # These apply to submodule URLs even after `git submodule init` has copied
  # them from `.gitmodules` into `.git/config`: git applies `insteadOf` when it
  # USES a URL, not when it records one. Both actions previously claimed the
  # opposite in a comment and carried a per-submodule token rewrite to work
  # around it; the contract suite pins the real behaviour.
  if [[ ${SCOPED_GIT_AUTH_REWRITES:-0} == 1 ]]; then
    SCOPED_GIT_AUTH_PAIRS+=("url.${url_base}.insteadOf" "git@github.com:")
    SCOPED_GIT_AUTH_PAIRS+=("url.${url_base}.insteadOf" "ssh://git@github.com/")
  fi

  for _owner in $owners; do
    [[ -z $_owner ]] && continue
    # The trailing slash is for readability only, and it is worth being exact
    # about why: git breaks its `http.<url>.*` path match on `/`, so
    # `<base><owner>` already fails to match `<base><owner>-evil/x`. The
    # boundary is git's, not ours -- do not "harden" it here with a manual
    # check, and do not assume dropping the slash would open it.
    SCOPED_GIT_AUTH_SCOPES+=("${url_base}${_owner}/")
  done
  for _prefix in $extra; do
    [[ -z $_prefix ]] && continue
    case "$_prefix" in
    https://*) ;;
    # Plaintext http is accepted for LOOPBACK only, and exists so the
    # contract suite can point a scope at its own local git server and watch
    # the credential arrive on the wire. Any other http:// prefix would put
    # a live App token on an unencrypted connection, so it is refused with
    # everything else that is not https.
    http://127.0.0.1:* | http://localhost:*) ;;
    *)
      echo "scoped-git-auth: extra-token-url-prefixes entry '$_prefix' is not an https:// URL" >&2
      return 2
      ;;
    esac
    SCOPED_GIT_AUTH_SCOPES+=("$_prefix")
  done

  # No token: the caller clones public repositories only. The rewrites (if
  # requested) still stand; there is simply no credential to scope.
  if [[ -z ${GH_TOKEN:-} ]]; then
    SCOPED_GIT_AUTH_SCOPES=()
    return 0
  fi

  if [[ ${#SCOPED_GIT_AUTH_SCOPES[@]} -eq 0 ]]; then
    echo "scoped-git-auth: a token was supplied but no scope (token-owner and extra-token-url-prefixes are both empty)" >&2
    return 2
  fi

  # Basic auth with the App token as the password -- exactly what
  # `x-access-token:<token>@` encoded positionally in the URL. Same credential,
  # carried in a header instead of a URL.
  local blob
  blob="$(scoped_git_auth_b64 "$(printf 'x-access-token:%s' "$GH_TOKEN")")"
  if [[ ${SCOPED_GIT_AUTH_MASK:-0} == 1 ]]; then
    printf '::add-mask::%s\n' "$blob"
  fi
  local _scope
  for _scope in "${SCOPED_GIT_AUTH_SCOPES[@]}"; do
    SCOPED_GIT_AUTH_PAIRS+=("http.${_scope}.extraHeader" "AUTHORIZATION: basic ${blob}")
  done
  return 0
}

# `scoped_git_auth_export` -- install SCOPED_GIT_AUTH_PAIRS into this process's
# environment as git's numbered configuration, APPENDING to anything already
# there.
#
# Appending is not politeness. A caller may run after `setup-nix` has already
# put its own `GIT_CONFIG_COUNT` into the job environment; renumbering from zero
# would silently drop that configuration for every later step of the job.
# Exact duplicates are skipped for the mirror-image reason: `http.extraHeader` is
# multi-valued, so re-adding an identical pair makes git send the same
# `Authorization` header twice, which is a malformed request rather than a
# doubly-authenticated one.
scoped_git_auth_export() {
  local n="${GIT_CONFIG_COUNT:-0}"
  local i key value j have kn vn

  # Indirect expansion (`${!name-}`) rather than a nameref: GitHub's macOS
  # runner images ship bash 3.2, `declare -n` needs 4.3, and `setup-nix`
  # deliberately supports those runners.
  for ((i = 0; i < ${#SCOPED_GIT_AUTH_PAIRS[@]}; i += 2)); do
    key="${SCOPED_GIT_AUTH_PAIRS[i]}"
    value="${SCOPED_GIT_AUTH_PAIRS[i + 1]}"
    have=0
    for ((j = 0; j < n; j++)); do
      kn="GIT_CONFIG_KEY_${j}"
      vn="GIT_CONFIG_VALUE_${j}"
      if [[ ${!kn-} == "$key" && ${!vn-} == "$value" ]]; then
        have=1
        break
      fi
    done
    [[ $have == 1 ]] && continue
    printf -v "GIT_CONFIG_KEY_${n}" '%s' "$key"
    printf -v "GIT_CONFIG_VALUE_${n}" '%s' "$value"
    export "GIT_CONFIG_KEY_${n}" "GIT_CONFIG_VALUE_${n}"
    n=$((n + 1))
  done

  export GIT_CONFIG_COUNT="$n"
  # Without a URL-embedded credential a misconfigured scope would block on an
  # interactive prompt instead of failing; make it fail.
  export GIT_TERMINAL_PROMPT=0
}

# Clear invocation configuration only inside the private command subshell.
# It must not override the scoped file or seed the shared deduplication step.
_scoped_git_auth_clear_invocation_config() {
  local key
  for key in "${!GIT_CONFIG_@}"; do
    case "$key" in GIT_CONFIG_COUNT|GIT_CONFIG_PARAMETERS|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$key" ;; esac
  done
  unset GIT_CONFIG
}

# Run a command with the same scoped headers through Git's supported global
# configuration channel. Repro deliberately scrubs numbered invocation config
# before cross-repository Git calls; GIT_CONFIG_GLOBAL survives that boundary.
# The credential exists only in a private temporary file for this command, never
# in a checkout, a persistent global config, a URL or a subprocess argument.
scoped_git_auth_with_global() (
  # A caller's xtrace must not echo the derived header while it is rendered.
  case $- in *x*) set +x ;; esac
  local scratch config key scope value section attribute i kn vn have_pairs=0
  scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-git-auth.XXXXXXXX")" || return
  config="${scratch}/config"
  trap 'rm -f -- "$config"; rmdir -- "$scratch"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  SCOPED_GIT_AUTH_REWRITES=1 scoped_git_auth_build || return
  scoped_git_auth_report
  _scoped_git_auth_clear_invocation_config
  export GIT_CONFIG_COUNT=0
  # Reuse the existing exact key/value deduplication. Never invoke its
  # array-length loop on an empty Bash 3.2 array under nounset.
  for key in ${SCOPED_GIT_AUTH_PAIRS[@]+"${SCOPED_GIT_AUTH_PAIRS[@]}"}; do have_pairs=1; break; done
  if [ "$have_pairs" -eq 1 ]; then scoped_git_auth_export; fi
  (
    umask 077
    set -C
    {
      # Do not let a runner's persistent helper save a credential or answer
      # instead of the scoped header under test.
      printf '[credential]\n\thelper =\n'
      # Match authenticated-clone's process-wide Windows Git path support.
      # Importing the runner's whole global config would also import credentials.
      printf '[core]\n\tlongpaths = true\n'
      for ((i = 0; i < GIT_CONFIG_COUNT; i++)); do
        kn="GIT_CONFIG_KEY_${i}"; vn="GIT_CONFIG_VALUE_${i}"
        key="${!kn}"; value="${!vn}"
        case "$key" in
          http.*.extraHeader)
            section=http; attribute=extraHeader
            scope="${key#http.}"; scope="${scope%.extraHeader}" ;;
          url.*.insteadOf)
            section=url; attribute=insteadOf
            scope="${key#url.}"; scope="${scope%.insteadOf}" ;;
          *) echo 'scoped-git-auth: unsupported private-config key' >&2; exit 2 ;;
        esac
        # Git quoted subsection/value escaping, without passing the secret to
        # `git config` argv. Newlines cannot become injected config sections.
        scope="${scope//\\/\\\\}"; scope="${scope//\"/\\\"}"
        scope="${scope//$'\n'/\\n}"; scope="${scope//$'\t'/\\t}"; scope="${scope//$'\b'/\\b}"
        value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
        value="${value//$'\n'/\\n}"; value="${value//$'\t'/\\t}"; value="${value//$'\b'/\\b}"
        printf '[%s "%s"]\n\t%s = "%s"\n' "$section" "$scope" "$attribute" "$value"
      done
    } >"$config"
  ) || return

  _scoped_git_auth_clear_invocation_config
  export GIT_CONFIG_GLOBAL="$config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  "$@"
)

# `scoped_git_auth_emit <sink>` -- print SCOPED_GIT_AUTH_PAIRS as `KEY=VALUE`
# lines to <sink> (a file, e.g. `$GITHUB_ENV`) or to stdout when <sink> is empty.
# Numbering starts at 0: this is for `setup-nix`, whose whole job is to define
# the job-wide git configuration, and which must not inherit a partial one.
scoped_git_auth_emit() {
  local sink="${1:-}"
  local i n=0 out=()

  for ((i = 0; i < ${#SCOPED_GIT_AUTH_PAIRS[@]}; i += 2)); do
    out+=("GIT_CONFIG_KEY_${n}=${SCOPED_GIT_AUTH_PAIRS[i]}")
    out+=("GIT_CONFIG_VALUE_${n}=${SCOPED_GIT_AUTH_PAIRS[i + 1]}")
    n=$((n + 1))
  done
  out+=("GIT_CONFIG_COUNT=${n}")
  out+=("GIT_TERMINAL_PROMPT=0")

  if [[ -n $sink ]]; then
    printf '%s\n' "${out[@]}" >>"$sink"
  else
    printf '%s\n' "${out[@]}"
  fi
}

# `scoped_git_auth_report` -- say what was covered, without saying with what.
scoped_git_auth_report() {
  local count=0 _scope
  for _scope in ${SCOPED_GIT_AUTH_SCOPES[@]+"${SCOPED_GIT_AUTH_SCOPES[@]}"}; do count=$((count + 1)); done
  if [[ $count -eq 0 ]]; then
    echo "scoped-git-auth: no token supplied; git is configured for public clones only."
    return 0
  fi
  echo "scoped-git-auth: git credential scoped to ${count} URL prefix(es):"
  for _scope in ${SCOPED_GIT_AUTH_SCOPES[@]+"${SCOPED_GIT_AUTH_SCOPES[@]}"}; do
    echo "  ${_scope}"
  done
}

# `scoped_git_auth_owner_of <owner/name>` -- the owner half of a `owner/name`
# repository spec, or empty when the spec has no owner.
scoped_git_auth_owner_of() {
  case "$1" in
  */*) printf '%s' "${1%%/*}" ;;
  *) printf '' ;;
  esac
}

# `scoped_git_auth_require_covered <what> <owner...>` -- fail loudly when an
# owner this job is about to clone from is not one the token is scoped to.
#
# THIS IS THE POINT OF THE FUNCTION, so it is worth stating plainly: before the
# credential was owner-scoped, a mismatch here was invisible -- the catch-all
# authenticated every github.com URL, so cloning `some-other-org/thing` worked by
# accident. It now fails, and it fails as a bare 403/404 from GitHub on a private
# repository, which reads as "the repo does not exist". That diagnostic has cost
# this org real hours. So the disagreement is detected here, by name, before the
# first fetch.
scoped_git_auth_require_covered() {
  local what="$1"
  shift
  local owners="${TOKEN_OWNERS:-metacraft-labs}"
  local bad=() _o _t found

  for _o in "$@"; do
    [[ -z $_o ]] && continue
    found=0
    for _t in $owners; do
      [[ $_o == "$_t" ]] && {
        found=1
        break
      }
    done
    [[ $found == 0 ]] && bad+=("$_o")
  done

  [[ ${#bad[@]} -eq 0 ]] && return 0

  echo "::error::${what} is configured to clone from GitHub owner(s) [${bad[*]}], but the CI token for this job is scoped to [${owners}]. These two must be changed together: the Git CLI credential is installed as an 'http.https://github.com/<owner>/.extraHeader', so a private repository under an owner outside that list is not authenticated and GitHub answers 404 -- indistinguishable from a typo in the repository name. Fix by adding the owner to the action's 'token-owner' input (it is whitespace-separated and accepts several), or by cloning from an owner already in it." >&2
  return 1
}
