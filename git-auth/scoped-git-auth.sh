#!/usr/bin/env bash
#
# scoped-git-auth.sh -- the one place in this repo that decides how a CI GitHub
# token is handed to git. SOURCE it; it defines functions and sets nothing on
# its own but SCOPED_GIT_AUTH_HELPER, the path of the helper it configures.
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
#                           GIT_CONFIG_COUNT/KEY_n/VALUE_n, on top of whatever
#                           was already there: unrelated entries are kept, an
#                           inherited header for a covered URL is REPLACED (two
#                           would be a 400). Nothing touches disk; child
#                           processes (including `git submodule update
#                           --recursive`) inherit it, and nothing else does.
#   scoped_git_auth_emit    The JOB-SCOPED credential, for `$GITHUB_ENV`, which
#                           `setup-nix` and `refresh-build-auth` install for
#                           every later step. It is NOT a header: it is a
#                           `credential.<scope>.helper` per covered prefix that
#                           runs ./git-credential-job-token.sh, which reads the
#                           token from `$MCL_JOB_CREDENTIALS_DIR/git-token`
#                           whenever Git asks. This function writes that file
#                           (atomically, and not at all while the job's
#                           credential broker owns it) and prints the merged
#                           numbered configuration as `KEY=VALUE` lines. See
#                           "THE JOB-SCOPED CREDENTIAL" below.
#   scoped_git_auth_with_global  Run a command through a private temporary
#                           GIT_CONFIG_GLOBAL file, then remove it. This is for
#                           tools such as Repro that scrub numbered config. It
#                           carries the same helper, pointed at the job's token
#                           file when GH_TOKEN is the job's token, and at a
#                           token file in the same private directory otherwise.
#
# THE JOB-SCOPED CREDENTIAL
# -------------------------
# A GitHub App installation token lives one hour
# (https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
# The job-scoped credential used to be the same `http.<scope>.extraHeader` the
# step-local path uses, carried in `GIT_CONFIG_*` through `$GITHUB_ENV`. The
# runner copies that environment into each step when the step starts and
# nothing can change it afterwards, so Git kept presenting the first token the
# job was handed, and a Git operation more than an hour after that mint failed
# with `could not read Username` whether or not a broker kept Nix's credential
# fresh. Now, for each covered URL prefix, the job carries
#
#     http.<scope>.extraHeader =                    (reset: no preemptive header)
#     credential.<scope>.helper =                   (reset: no inherited helper)
#     credential.<scope>.helper = !/bin/sh '<this dir>/git-credential-job-token.sh' '<credential dir>'
#
# Git sends the request without credentials, GitHub answers a private
# repository with a 401 challenge, Git runs the helper and retries; a public
# repository is fetched anonymously. Both resets are load-bearing. An empty
# `credential.<url>.helper` clears every helper configured before it, so a
# runner's own helper (Git Credential Manager, `gh auth setup-git`, a
# `~/.git-credentials` store) cannot answer for the scope; an empty
# `http.<url>.extraHeader` clears the headers Git would otherwise send
# preemptively for it, such as the `http.https://github.com/.extraheader`
# `actions/checkout` persists into a checkout, which would otherwise be sent
# instead of challenging: GitHub answers a token without access to the
# repository with 404, which Git does not retry, and a 401 retried through the
# helper would carry that header beside the helper's credential. Both forms are documented: an empty helper
# value in https://git-scm.com/docs/gitcredentials#_configuration_options and
# an empty extraHeader in https://git-scm.com/docs/git-config#Documentation/git-config.txt-httpextraHeader.
#
# HOW GIT SCOPES IT. Git selects `credential.<url>.*` entries with the same
# URL matcher as `http.<url>.*`: scheme, host and port exactly, and the path as
# a prefix that breaks on `/`. The matcher sees the request's full path even
# though `credential.useHttpPath` is off (Git drops the path from the context
# only after the configuration is selected, and only then hands the helper a
# path-less request), so `credential.https://github.com/<owner>/.helper` answers
# for that owner's repositories and for no other owner's, without
# `useHttpPath`. Measured against git 2.54 by the contract suites, which
# assert that an owner outside the scopes gets no credential.
#
# Nothing secret is in the environment, in $HOME or in a URL: the numbered
# configuration names the helper and the credential directory, and the token is
# only in the file, which is mode 600 in a mode-700 directory under
# `$RUNNER_TEMP` (emptied by the runner between jobs). A missing directory or
# file makes the helper answer nothing, so a stale reference on a persistent
# runner means no credential rather than a dead one.
#
# WHO WRITES `git-token`. Everything that rewrites the job's Nix credential
# rewrites this file in the same action: the broker
# (refresh-build-auth/job-credentials.cjs), refresh-build-auth (through this
# file) and setup-nix (through setup-nix/configure-git-auth.sh, which calls
# scoped_git_auth_emit). While the broker runs and owns the file it is the
# only writer (scoped_git_auth_broker_owns_git_token; the same rule as
# brokerOwnsGitToken there -- keep the two in step). A job that writes over Git
# declares `git-access: write` on setup-dev-env, which records `write` in
# `<credential dir>/git-access`; the broker, whose tokens are `contents: read`,
# then never writes the Git token file, and refresh-build-auth renews it.
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
# Contract suites: ./authenticated-clone-test.sh, ./job-credential-helper-test.sh
# and ./test-private-global-config.py, and ../setup-nix/configure-git-auth-test.sh.

# The helper this file configures, as an absolute path Git can run. Computed
# once, when the file is sourced, from where the file itself lives: the action
# checkout that sourced it stays in place for the rest of the job. On Windows
# the step's bash is MSYS; `pwd -W` gives the `D:/a/...` form that both that
# shell and the MSYS sh Git for Windows runs helpers with accept. Elsewhere
# `pwd -W` is not an option and plain `pwd` answers.
_scoped_git_auth_source="${BASH_SOURCE[0]:-}"
case "$_scoped_git_auth_source" in
*/*) _scoped_git_auth_source="${_scoped_git_auth_source%/*}" ;;
*) _scoped_git_auth_source=. ;;
esac
SCOPED_GIT_AUTH_HELPER="$(CDPATH='' cd -- "$_scoped_git_auth_source" && { pwd -W 2>/dev/null || pwd; })/git-credential-job-token.sh"
unset _scoped_git_auth_source

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

# `_scoped_git_auth_is_credential_key <key>` -- true when <key> names an
# `http.<url>.extraHeader`, compared the way git compares it: the section and
# variable names case-insensitively. (The URL is compared case-insensitively
# too; its scheme and host are, to git, and a path spelled in two cases is not
# a distinction anything in this org relies on.) Pure bash 3.2: `nocasematch`,
# restored afterwards, rather than `${var,,}`.
_scoped_git_auth_is_credential_key() {
  local rc=1 nocase_was_set=0
  shopt -q nocasematch && nocase_was_set=1
  shopt -s nocasematch
  [[ $1 == http.*.extraheader ]] && rc=0
  [[ $nocase_was_set == 1 ]] || shopt -u nocasematch
  return "$rc"
}

# `_scoped_git_auth_same_key <a> <b>` -- the two keys are the same git key,
# compared case-insensitively (see above).
_scoped_git_auth_same_key() {
  local rc=1 nocase_was_set=0
  shopt -q nocasematch && nocase_was_set=1
  shopt -s nocasematch
  [[ $1 == "$2" ]] && rc=0
  [[ $nocase_was_set == 1 ]] || shopt -u nocasematch
  return "$rc"
}

# `_scoped_git_auth_is_helper_key <key>` -- true when <key> names a
# `credential.<url>.helper`, compared as git compares it (see above).
_scoped_git_auth_is_helper_key() {
  local rc=1 nocase_was_set=0
  shopt -q nocasematch && nocase_was_set=1
  shopt -s nocasematch
  [[ $1 == credential.*.helper ]] && rc=0
  [[ $nocase_was_set == 1 ]] || shopt -u nocasematch
  return "$rc"
}

# `_scoped_git_auth_for_git <path>` -- <path> spelled for a helper command
# line: backslashes become forward slashes. A Windows runner hands out
# `D:\a\_temp`; the MSYS sh Git for Windows runs helpers with, Node and Git all
# accept `D:/a/_temp`, and a backslash is one less thing to quote.
_scoped_git_auth_for_git() {
  printf '%s' "${1//\\//}"
}

# `_scoped_git_auth_existing_job_dir` -- whether `$MCL_JOB_CREDENTIALS_DIR`
# names a usable job credential directory, as scoped_git_auth_job_dir below
# defines usable. Sets _SGA_EXISTING_JOB_DIR to it and returns 0 when it does;
# returns 1 when it is unset or unusable, and 3 when it is a directory another
# user owns (which the caller reports). Prints nothing.
_scoped_git_auth_existing_job_dir() {
  local dir="${MCL_JOB_CREDENTIALS_DIR:-}" windows=0
  case "${OSTYPE:-}" in msys* | cygwin* | win32*) windows=1 ;; esac
  _SGA_EXISTING_JOB_DIR=""
  case "$dir" in
  /* | [A-Za-z]:[\\/]*) ;;
  *) return 1 ;;
  esac
  [[ -d $dir && ! -L $dir ]] || return 1
  [[ $windows == 1 || -O $dir ]] || return 3
  _SGA_EXISTING_JOB_DIR="$dir"
  return 0
}

# `scoped_git_auth_job_dir` -- the job's private credential directory: the
# validated `$MCL_JOB_CREDENTIALS_DIR`, or a new mode-700 directory under
# `$RUNNER_TEMP` when that is unset or unusable (no setup-nix and no broker ran
# first, as on Windows). Sets SCOPED_GIT_AUTH_JOB_DIR, and
# SCOPED_GIT_AUTH_JOB_DIR_CREATED=1 when the directory is new, in which case
# it is also exported as MCL_JOB_CREDENTIALS_DIR so a Nix refresh later in the
# same step (refresh-build-auth) uses the same directory.
#
# "Usable" is what job-credentials.cjs credentialsDir() requires: an absolute
# path to a real directory (not a symlink), and on POSIX owned by this user.
# The mode is set to 700 here as setup-nix sets it. Pure bash plus mktemp
# (and mv, to replace the token file), tools setup-nix's credential step
# already relies on.
scoped_git_auth_job_dir() {
  local dir="" root windows=0 rc=0
  case "${OSTYPE:-}" in msys* | cygwin* | win32*) windows=1 ;; esac
  SCOPED_GIT_AUTH_JOB_DIR=""
  SCOPED_GIT_AUTH_JOB_DIR_CREATED=0
  _scoped_git_auth_existing_job_dir || rc=$?
  if [[ $rc == 0 ]]; then
    dir="$_SGA_EXISTING_JOB_DIR"
  elif [[ $rc == 3 ]]; then
    echo "scoped-git-auth: MCL_JOB_CREDENTIALS_DIR is not owned by this user; using a new job credential directory" >&2
  fi
  if [[ -z $dir ]]; then
    root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
    dir="$(umask 077 && mktemp -d "${root%[\\/]}/mcl-job-credentials.XXXXXXXX")" || {
      echo "scoped-git-auth: cannot create the job credential directory under '$root'" >&2
      return 2
    }
    SCOPED_GIT_AUTH_JOB_DIR_CREATED=1
  fi
  dir="$(_scoped_git_auth_for_git "$dir")"
  case "$dir" in
  *"'"* | *$'\n'* | *$'\r'* | *[[:space:]]*)
    # A quote or a newline cannot be carried in the helper's command line,
    # and whitespace cannot be carried in the nix.conf `!include` the same
    # directory serves.
    echo "scoped-git-auth: the job credential directory path '$dir' contains a quote or whitespace" >&2
    return 2
    ;;
  esac
  # mktemp -d creates its directory mode 700. One handed over by an earlier
  # step is made private as setup-nix makes it, where chmod is on PATH: the
  # refresh path runs with whatever PATH the job has, and chmod is the one
  # tool it would otherwise need for this.
  if [[ $windows == 0 && $SCOPED_GIT_AUTH_JOB_DIR_CREATED == 0 ]] && command -v chmod >/dev/null 2>&1; then
    chmod 700 "$dir" || return 2
  fi
  SCOPED_GIT_AUTH_JOB_DIR="$dir"
  if [[ $SCOPED_GIT_AUTH_JOB_DIR_CREATED == 1 ]]; then
    export MCL_JOB_CREDENTIALS_DIR="$dir"
  fi
  return 0
}

# `scoped_git_auth_git_access <dir>` -- `write` when the job declared that it
# writes over Git (`<dir>/git-access` holds `write`, recorded by setup-dev-env's
# broker start for `git-access: write`), `read` otherwise.
scoped_git_auth_git_access() {
  local access=""
  if [[ -f $1/git-access ]]; then
    { IFS= read -r access <"$1/git-access"; } 2>/dev/null || :
  fi
  access="${access//[[:space:]]/}"
  if [[ $access == write ]]; then printf 'write'; else printf 'read'; fi
}

# `scoped_git_auth_broker_owns_git_token <dir>` -- true while the job's
# credential broker owns `<dir>/git-token`, so no other writer may replace it.
#
# OWNERSHIP RULE (job-credentials.cjs brokerOwnsGitToken; keep the two in step,
# and in step with setup-nix's broker_owns_token for the Nix files): the broker
# is running -- `broker.stop` is absent and `broker.pid` is a positive decimal
# naming a process we can signal whose argv, where /proc shows it, ends in
# `job-credentials.cjs daemon`, so a reused pid owns nothing -- AND it has
# written `git-token`, AND the job did not declare `git-access: write`. A
# broker that has not written the file (one from an older revision of these
# actions) owns nothing, so a job is never left with no Git token at all.
#
# Bash 3.2 and builtins only: no mapfile, no negative subscripts, no cat.
scoped_git_auth_broker_owns_git_token() {
  local dir="$1" pid_text="" pid arg last="" prev="" n=0
  # In a variable: bash 3.2's parser mis-reads a literal regex with a group.
  local pid_re='^[[:space:]]*([1-9][0-9]*)[[:space:]]*$'
  [[ -f $dir/git-token && -f $dir/broker.pid && ! -e $dir/broker.stop ]] || return 1
  [[ "$(scoped_git_auth_git_access "$dir")" == read ]] || return 1
  IFS= read -r -d '' pid_text 2>/dev/null <"$dir/broker.pid" || :
  [[ $pid_text =~ $pid_re ]] || return 1
  pid="${BASH_REMATCH[1]}"
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -e /proc/self ]] || return 0
  [[ -r /proc/$pid/cmdline ]] || return 1
  while IFS= read -r -d '' arg; do
    prev="$last"
    last="$arg"
    n=$((n + 1))
  done 2>/dev/null <"/proc/$pid/cmdline"
  [[ $n -ge 2 && $last == daemon && ${prev##*/} == job-credentials.cjs ]]
}

# `scoped_git_auth_write_git_token <dir> <token>` -- replace `<dir>/git-token`
# atomically: the token goes into a new mode-600 file in the same directory,
# which is then renamed over the old one, so the helper reads the old token or
# the new one and never part of either. `set -C` makes the temporary file's
# creation exclusive without mktemp.
scoped_git_auth_write_git_token() {
  local dir="$1" token="$2" tmp
  case "$token" in
  '' | *[[:space:]]*)
    echo "scoped-git-auth: refusing an empty or malformed token" >&2
    return 2
    ;;
  esac
  tmp="$dir/.git-token.$$.${RANDOM}${RANDOM}"
  (umask 077 && set -C && printf '%s\n' "$token" >"$tmp") || {
    echo "scoped-git-auth: cannot write the job's Git token file in '$dir'" >&2
    return 2
  }
  mv -f -- "$tmp" "$dir/git-token" || {
    rm -f -- "$tmp"
    echo "scoped-git-auth: cannot install the job's Git token file in '$dir'" >&2
    return 2
  }
}

# `_scoped_git_auth_helper_pairs <dir>` -- set _SGA_HELPER_PAIRS to the
# credential-free pairs that route every covered scope to the helper reading
# `<dir>/git-token`: SCOPED_GIT_AUTH_PAIRS without its headers (that is, the
# scheme rewrites when they were asked for), then per scope a header reset, a
# helper reset and the helper. See "THE JOB-SCOPED CREDENTIAL" above.
_scoped_git_auth_helper_pairs() {
  local dir="$1" i command _scope
  command="!/bin/sh '${SCOPED_GIT_AUTH_HELPER}' '${dir}'"
  case "$SCOPED_GIT_AUTH_HELPER" in
  *"'"* | *$'\n'*)
    echo "scoped-git-auth: the helper path '$SCOPED_GIT_AUTH_HELPER' contains a quote or a newline" >&2
    return 2
    ;;
  esac
  _SGA_HELPER_PAIRS=()
  [[ -n ${SCOPED_GIT_AUTH_PAIRS[*]+set} ]] || SCOPED_GIT_AUTH_PAIRS=()
  for ((i = 0; i < ${#SCOPED_GIT_AUTH_PAIRS[@]}; i += 2)); do
    _scoped_git_auth_is_credential_key "${SCOPED_GIT_AUTH_PAIRS[i]}" && continue
    _SGA_HELPER_PAIRS+=("${SCOPED_GIT_AUTH_PAIRS[i]}" "${SCOPED_GIT_AUTH_PAIRS[i + 1]}")
  done
  for _scope in ${SCOPED_GIT_AUTH_SCOPES[@]+"${SCOPED_GIT_AUTH_SCOPES[@]}"}; do
    _SGA_HELPER_PAIRS+=("http.${_scope}.extraHeader" "")
    _SGA_HELPER_PAIRS+=("credential.${_scope}.helper" "")
    _SGA_HELPER_PAIRS+=("credential.${_scope}.helper" "$command")
  done
}

# `_scoped_git_auth_merge` -- the numbered configuration this process should
# carry once SCOPED_GIT_AUTH_PAIRS is installed over what it already carries.
# Sets _SGA_KEYS/_SGA_VALUES (dense, index = position) and _SGA_N. Reads the
# environment; changes nothing in it.
#
# THE RULE FOR A CREDENTIAL HEADER IS REPLACE, NOT APPEND. `extraHeader` is
# multi-valued: two entries for the same URL make git send two `Authorization`
# headers, and GitHub refuses the request (`remote: Duplicate header:
# "Authorization"`, HTTP 400). An earlier step routinely leaves such an entry
# in the job environment -- `setup-nix` emits the job's credential through
# `$GITHUB_ENV` -- and a later step routinely holds a DIFFERENT token for the
# same scope (`setup-dev-env` hands its clones the credential broker's fresher
# token). Skipping only exact duplicates, as this used to, is therefore not
# enough: the values differ, both were kept, and every clone in the step was
# refused. So an inherited header at a URL this call covers is overwritten in
# place with the caller's value -- the caller's credential is the one it chose
# for this work -- and any further copies of that key are dropped.
#
# EVERYTHING ELSE IS KEPT, in order. Unrelated entries (an extraHeader for a
# URL this call does not cover, `core.longpaths`, `url.*.insteadOf`) keep their
# values and their relative order; indices shift down only when a duplicate
# header is dropped. Non-credential pairs keep the previous rule: an exact
# duplicate is skipped, anything else is appended (a later single-valued entry
# wins in git, and `insteadOf` is legitimately multi-valued).
#
# A `credential.<url>.helper` IS REPLACED AS A GROUP. The key is multi-valued
# and its values are an ordered list (an empty value, then the helper), so the
# first time the incoming pairs name such a key every inherited entry for it
# is dropped and the incoming values are appended in order. A second emit in
# the same job (setup-nix run twice, refresh-build-auth) therefore leaves one
# reset and one helper per scope, not two of each.
#
# A numbered entry whose key is unset or empty is dropped: git refuses the
# whole environment over one (`missing config key GIT_CONFIG_KEY_n`), so
# carrying it forward would break every later git invocation.
#
# Values are only ever copied between variables; nothing here prints one.
_scoped_git_auth_merge() {
  local n="${GIT_CONFIG_COUNT:-0}" i j k key value kn vn found have purged=$'\n'
  local -a keys=() values=()
  _SGA_KEYS=()
  _SGA_VALUES=()
  _SGA_N=0
  [[ $n =~ ^[0-9]+$ ]] || n=0
  for ((j = 0; j < n; j++)); do
    kn="GIT_CONFIG_KEY_${j}"
    vn="GIT_CONFIG_VALUE_${j}"
    [[ -n ${!kn-} ]] || continue
    _SGA_KEYS[_SGA_N]="${!kn}"
    _SGA_VALUES[_SGA_N]="${!vn-}"
    _SGA_N=$((_SGA_N + 1))
  done

  for ((i = 0; i < ${#SCOPED_GIT_AUTH_PAIRS[@]}; i += 2)); do
    key="${SCOPED_GIT_AUTH_PAIRS[i]}"
    value="${SCOPED_GIT_AUTH_PAIRS[i + 1]}"
    if _scoped_git_auth_is_credential_key "$key"; then
      # Rebuild: the first entry for this key takes the new value where it
      # stands, later ones are dropped, the rest is copied through.
      keys=()
      values=()
      k=0
      found=0
      for ((j = 0; j < _SGA_N; j++)); do
        if _scoped_git_auth_same_key "${_SGA_KEYS[j]}" "$key"; then
          [[ $found == 1 ]] && continue
          found=1
          keys[k]="${_SGA_KEYS[j]}"
          values[k]="$value"
        else
          keys[k]="${_SGA_KEYS[j]}"
          values[k]="${_SGA_VALUES[j]}"
        fi
        k=$((k + 1))
      done
      if [[ $found == 0 ]]; then
        keys[k]="$key"
        values[k]="$value"
        k=$((k + 1))
      fi
      _SGA_KEYS=()
      _SGA_VALUES=()
      for ((j = 0; j < k; j++)); do
        _SGA_KEYS[j]="${keys[j]}"
        _SGA_VALUES[j]="${values[j]}"
      done
      _SGA_N=$k
      continue
    fi
    if _scoped_git_auth_is_helper_key "$key"; then
      # Drop the inherited entries for this key once, then append in order.
      case "$purged" in *$'\n'"$key"$'\n'*) ;; *)
        purged+="$key"$'\n'
        keys=()
        values=()
        k=0
        for ((j = 0; j < _SGA_N; j++)); do
          _scoped_git_auth_same_key "${_SGA_KEYS[j]}" "$key" && continue
          keys[k]="${_SGA_KEYS[j]}"
          values[k]="${_SGA_VALUES[j]}"
          k=$((k + 1))
        done
        _SGA_KEYS=()
        _SGA_VALUES=()
        for ((j = 0; j < k; j++)); do
          _SGA_KEYS[j]="${keys[j]}"
          _SGA_VALUES[j]="${values[j]}"
        done
        _SGA_N=$k
        ;;
      esac
      _SGA_KEYS[_SGA_N]="$key"
      _SGA_VALUES[_SGA_N]="$value"
      _SGA_N=$((_SGA_N + 1))
      continue
    fi
    have=0
    for ((j = 0; j < _SGA_N; j++)); do
      if [[ ${_SGA_KEYS[j]} == "$key" && ${_SGA_VALUES[j]} == "$value" ]]; then
        have=1
        break
      fi
    done
    [[ $have == 1 ]] && continue
    _SGA_KEYS[_SGA_N]="$key"
    _SGA_VALUES[_SGA_N]="$value"
    _SGA_N=$((_SGA_N + 1))
  done
}

# `scoped_git_auth_export` -- install SCOPED_GIT_AUTH_PAIRS into this process's
# environment as git's numbered configuration, on top of whatever is already
# there (see _scoped_git_auth_merge for exactly how).
#
# Not renumbering from zero is not politeness. A caller may run after
# `setup-nix` has already put its own `GIT_CONFIG_COUNT` into the job
# environment; discarding it would silently drop that configuration for every
# later step of the job. But a credential header for a URL this call covers is
# REPLACED, never added beside the inherited one: two values for one
# `http.<url>.extraHeader` make git send two `Authorization` headers, which
# GitHub refuses with HTTP 400.
scoped_git_auth_export() {
  local old="${GIT_CONFIG_COUNT:-0}" j

  _scoped_git_auth_merge
  # Indirect assignment (`printf -v`) rather than a nameref: GitHub's macOS
  # runner images ship bash 3.2, `declare -n` needs 4.3, and `setup-nix`
  # deliberately supports those runners.
  for ((j = 0; j < _SGA_N; j++)); do
    printf -v "GIT_CONFIG_KEY_${j}" '%s' "${_SGA_KEYS[j]}"
    printf -v "GIT_CONFIG_VALUE_${j}" '%s' "${_SGA_VALUES[j]}"
    export "GIT_CONFIG_KEY_${j}" "GIT_CONFIG_VALUE_${j}"
  done
  # Entries past the new count are ignored by git; unset them anyway so a
  # dropped duplicate's value does not linger in every child's environment.
  [[ $old =~ ^[0-9]+$ ]] || old=0
  for ((j = _SGA_N; j < old; j++)); do
    unset "GIT_CONFIG_KEY_${j}" "GIT_CONFIG_VALUE_${j}"
  done
  _SGA_KEYS=()
  _SGA_VALUES=()

  export GIT_CONFIG_COUNT="$_SGA_N"
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

# `_scoped_git_auth_job_token_dir <token>` -- true when <token> is the job's
# current Git token: `$MCL_JOB_CREDENTIALS_DIR` is a usable job credential
# directory (see _scoped_git_auth_existing_job_dir) whose `git-token` is a
# regular file holding exactly <token>. Sets _SGA_JOB_TOKEN_DIR to the
# directory as a helper command line spells it. Compares in memory and prints
# nothing.
_scoped_git_auth_job_token_dir() {
  local want="$1" dir have=""
  _SGA_JOB_TOKEN_DIR=""
  [[ -n $want ]] || return 1
  _scoped_git_auth_existing_job_dir || return 1
  dir="$_SGA_EXISTING_JOB_DIR"
  [[ -f $dir/git-token && ! -L $dir/git-token ]] || return 1
  { IFS= read -r have <"$dir/git-token"; } 2>/dev/null || :
  [[ $have == "$want" ]] || return 1
  dir="$(_scoped_git_auth_for_git "$dir")"
  case "$dir" in *"'"* | *$'\n'* | *$'\r'* | *[[:space:]]*) return 1 ;; esac
  _SGA_JOB_TOKEN_DIR="$dir"
}

# Run a command with the job's credential shape through Git's supported global
# configuration channel. Repro deliberately scrubs numbered invocation config
# before cross-repository Git calls; GIT_CONFIG_GLOBAL survives that boundary.
#
# The private file carries the same configuration scoped_git_auth_emit puts in
# the job environment -- per scope a header reset, a helper reset and the
# helper. So a tool that runs Git itself (Repro, and anything it starts) gets
# the same 401-then-helper flow as every other Git in the job. Which token
# file the helper reads:
#
#   * The JOB's `$MCL_JOB_CREDENTIALS_DIR/git-token`, when GH_TOKEN is the
#     token that file holds right now (_scoped_git_auth_job_token_dir). The
#     broker and refresh-build-auth replace that file in place, so a command
#     that runs longer than the token's hour -- `repro develop` cloning many
#     siblings -- is handed each rotation, as every other Git in the job is.
#     Nothing is written for this command and nothing of the job's is removed.
#   * Otherwise a `git-token` file in the same private directory as the
#     configuration, holding GH_TOKEN for this command only: there is no job
#     credential directory or token file (no setup-nix and no broker ran
#     first), or the caller passes a token other than the job's, such as the
#     broker's read token in a job whose Git token is a writing `gh-token`,
#     or a token the file no longer holds because it has been rotated since
#     the caller was handed it. Equality is the test because it never hands a
#     command a token other than the one it was given. That file lives no
#     longer than the command.
#
# The token exists only in a mode-600 file in a mode-700 directory: never in a
# checkout, a persistent global config, a URL, the config file or a
# subprocess argument.
scoped_git_auth_with_global() (
  # A caller's xtrace must not echo anything derived from the token.
  case $- in *x*) set +x ;; esac
  local scratch config key scope value section attribute i
  scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-git-auth.XXXXXXXX")" || return
  config="${scratch}/config"
  trap 'rm -f -- "$config" "$scratch/git-token"; rmdir -- "$scratch"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  SCOPED_GIT_AUTH_REWRITES=1 scoped_git_auth_build || return
  scoped_git_auth_report
  _SGA_HELPER_PAIRS=()
  if [[ -n ${SCOPED_GIT_AUTH_SCOPES[*]+set} && ${#SCOPED_GIT_AUTH_SCOPES[@]} -gt 0 ]]; then
    if _scoped_git_auth_job_token_dir "$GH_TOKEN"; then
      # The caller was handed the job's own Git token: read the job's file,
      # which the broker and refresh-build-auth rotate, so a command that
      # outlives the token it started with (a long `repro develop`) keeps a
      # valid credential.
      _scoped_git_auth_helper_pairs "$_SGA_JOB_TOKEN_DIR" || return
    else
      chmod 700 "$scratch" 2>/dev/null || :
      scoped_git_auth_write_git_token "$scratch" "$GH_TOKEN" || return
      _scoped_git_auth_helper_pairs "$(_scoped_git_auth_for_git "$scratch")" || return
    fi
  else
    # No token: only the credential-free scheme rewrites.
    for ((i = 0; i < ${#SCOPED_GIT_AUTH_PAIRS[@]}; i += 2)); do
      _SGA_HELPER_PAIRS+=("${SCOPED_GIT_AUTH_PAIRS[i]}" "${SCOPED_GIT_AUTH_PAIRS[i + 1]}")
    done
  fi
  (
    umask 077
    set -C
    {
      # Do not let a runner's persistent helper save a credential or answer
      # for a URL outside the scopes either.
      printf '[credential]\n\thelper =\n'
      # Match authenticated-clone's process-wide Windows Git path support.
      # Importing the runner's whole global config would also import credentials.
      printf '[core]\n\tlongpaths = true\n'
      for ((i = 0; i < ${#_SGA_HELPER_PAIRS[@]}; i += 2)); do
        key="${_SGA_HELPER_PAIRS[i]}"
        value="${_SGA_HELPER_PAIRS[i + 1]}"
        case "$key" in
          http.*.extraHeader)
            section=http; attribute=extraHeader
            scope="${key#http.}"; scope="${scope%.extraHeader}" ;;
          url.*.insteadOf)
            section=url; attribute=insteadOf
            scope="${key#url.}"; scope="${scope%.insteadOf}" ;;
          credential.*.helper)
            section=credential; attribute=helper
            scope="${key#credential.}"; scope="${scope%.helper}" ;;
          *) echo 'scoped-git-auth: unsupported private-config key' >&2; exit 2 ;;
        esac
        # Git quoted subsection/value escaping, without passing anything to
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

# `_scoped_git_auth_env_line <name> <value>` -- append one `$GITHUB_ENV`
# entry for <name> to the caller's `out` array (bash's dynamic scoping).
_scoped_git_auth_env_line() {
  local delim
  case "$2" in
  *$'\n'* | *$'\r'*)
    delim="SCOPED_GIT_AUTH_EOF"
    while [[ $2 == *"$delim"* ]]; do delim="${delim}_"; done
    out+=("${1}<<${delim}" "$2" "$delim")
    ;;
  *) out+=("${1}=${2}") ;;
  esac
}

# `scoped_git_auth_emit <sink>` -- install the JOB-SCOPED credential: write the
# job's Git token file and the job's numbered git configuration, as
# `$GITHUB_ENV` lines to <sink> (a file) or to stdout when <sink> is empty.
# Call scoped_git_auth_build first.
#
# With a token (GH_TOKEN, and so SCOPED_GIT_AUTH_SCOPES, non-empty):
#
#   1. The job credential directory is found or created
#      (scoped_git_auth_job_dir). A new one is announced to later steps with a
#      `MCL_JOB_CREDENTIALS_DIR=` line, so Nix and Git share it.
#   2. GH_TOKEN is written to `<dir>/git-token`, atomically, unless the job's
#      credential broker owns that file (scoped_git_auth_broker_owns_git_token):
#      then the broker's token, which is never older than the one this caller
#      was handed, is left in place.
#   3. The numbered configuration carries the helper pairs
#      (_scoped_git_auth_helper_pairs), not the header SCOPED_GIT_AUTH_PAIRS
#      holds. That header is for the step-local scoped_git_auth_export only.
#
# Without a token, SCOPED_GIT_AUTH_PAIRS (at most the credential-free scheme
# rewrites) is emitted as before and no file is touched.
#
# The WHOLE set is written, numbered from 0, with its own `GIT_CONFIG_COUNT`.
# A step's environment is the job environment earlier steps wrote, so writing
# the complete merged set is what replaces the job-wide configuration rather
# than layering on it. The merge is scoped_git_auth_export's: an inherited
# `http.<scope>.extraHeader` for a covered URL -- such as the static header an
# older revision of setup-nix installed -- is replaced by the empty reset, an
# inherited `credential.<scope>.helper` list is replaced as a whole, and
# unrelated inherited entries are carried forward, where writing a smaller
# `GIT_CONFIG_COUNT` over them used to hide them from every later step.
#
# A value containing a newline is written in the runner's multi-line form
# (`NAME<<DELIMITER`), so an inherited value can never inject a line of its
# own into `$GITHUB_ENV`. Diagnostics go to stderr: callers send stdout to
# `$GITHUB_ENV`. The token is written only to the file.
scoped_git_auth_emit() {
  # A caller's xtrace would print the token as an argument of the file write.
  # Turn it off for the call and back on afterwards; the body's explicit
  # `|| return` checks keep its failures without errexit.
  local rc=0
  case $- in
  *x*)
    set +x
    _scoped_git_auth_emit "$@" || rc=$?
    set -x
    return "$rc"
    ;;
  esac
  _scoped_git_auth_emit "$@"
}

_scoped_git_auth_emit() {
  local sink="${1:-}"
  local j out=()

  if [[ -n ${SCOPED_GIT_AUTH_SCOPES[*]+set} && ${#SCOPED_GIT_AUTH_SCOPES[@]} -gt 0 ]]; then
    scoped_git_auth_job_dir || return
    if scoped_git_auth_broker_owns_git_token "$SCOPED_GIT_AUTH_JOB_DIR"; then
      echo "scoped-git-auth: the job credential broker owns this job's Git token; keeping it rather than the token this step was handed" >&2
    else
      scoped_git_auth_write_git_token "$SCOPED_GIT_AUTH_JOB_DIR" "${GH_TOKEN:-}" || return
    fi
    _scoped_git_auth_helper_pairs "$SCOPED_GIT_AUTH_JOB_DIR" || return
    [[ $SCOPED_GIT_AUTH_JOB_DIR_CREATED == 1 ]] &&
      out+=("MCL_JOB_CREDENTIALS_DIR=${SCOPED_GIT_AUTH_JOB_DIR}")
    # Merge the helper pairs in place of the header pairs, for this call only.
    local -a SCOPED_GIT_AUTH_PAIRS=(${_SGA_HELPER_PAIRS[@]+"${_SGA_HELPER_PAIRS[@]}"})
    _scoped_git_auth_merge
  else
    _scoped_git_auth_merge
  fi
  for ((j = 0; j < _SGA_N; j++)); do
    _scoped_git_auth_env_line "GIT_CONFIG_KEY_${j}" "${_SGA_KEYS[j]}"
    _scoped_git_auth_env_line "GIT_CONFIG_VALUE_${j}" "${_SGA_VALUES[j]}"
  done
  out+=("GIT_CONFIG_COUNT=${_SGA_N}")
  out+=("GIT_TERMINAL_PROMPT=0")
  _SGA_KEYS=()
  _SGA_VALUES=()

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
