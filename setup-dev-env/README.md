# setup-dev-env

CI-side replay of the repository's deterministic dev environment.

After this composite action runs, subsequent steps invoke
`dev-exec <cmd>` to execute any command inside the same env that
a developer uses locally:

| flavor        | `dev-exec <cmd>` resolves to                                              |
| ------------- | ------------------------------------------------------------------------- |
| `nix`         | `nix develop [--override-input …] -c <cmd>`                               |
| `windows-diy` | `<cmd>` (env from `env.ps1` already loaded)                               |
| `reprobuild`  | Setup-project Repro environment, retaining the command's caller directory |

See the policy doc for the design rationale:
[metacraft-dev-guidelines/policies/ci-shared-dev-env.md](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/ci-shared-dev-env.md).

## Quick start

```yaml
jobs:
  test:
    strategy:
      matrix:
        include:
          - env: nix
            os: ubuntu-latest
          - env: windows-diy
            os: windows-latest
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
        with:
          env-flavor: ${{ matrix.env }}
          gh-token: ${{ secrets.GITHUB_TOKEN }}
      - run: dev-exec just test
```

## Inputs

| Input                   | Required | Description                                                                                                                                                               |
| ----------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `env-flavor`            | yes      | `nix` \| `windows-diy` \| `reprobuild`.                                                                                                                                   |
| `gh-token`              | no       | Forwarded to `setup-nix` so private flake inputs resolve.                                                                                                                 |
| `substituters`          | no       | Space-separated extra Nix substituter URLs, such as Attic cache URLs.                                                                                                     |
| `trusted-public-keys`   | no       | Space-separated signing keys for the extra substituters.                                                                                                                  |
| `flake-override-inputs` | no       | Newline-separated `NAME=PATH` entries; each becomes `--override-input NAME path:PATH` on every `nix develop` invocation. Use for sibling-repo overrides cloned alongside. |
| `env-ps1-path`          | no       | Path to `env.ps1` (windows-diy only). Defaults to `./env.ps1`.                                                                                                            |
| `sibling-strategy`      | no       | `auto` (default) \| `repro-lock` \| `clone-siblings`. Which mechanism provisions cross-repo siblings — see below.                                                         |
| `siblings`              | no       | Whitespace/newline-separated sibling list, overriding `.github/sibling-repos`. Reconciled against `repro.lock` on the repro path — see below.                             |
| `shared-store-path`     | no       | Where a shared, persistent reprobuild store is expected to be mounted. Defaults to `/srv/repro-store`; empty switches the probe off. See below.                           |

### Reprobuild release selection

`repro-version` selects a release tag (for example `v0.2.10`) or `latest`
(the default) whenever the reprobuild flavor or repro-lock strategy installs
Reprobuild. An ambient CLI never overrides the requested release. The shared
installer checks the downloaded archive and its reported release version;
this selection check alone does not qualify complete SDK or warm-store reuse.
Set `repro-from-source: true` to choose the source route instead; that route
ignores `repro-version` and uses the source inputs below.

For the reprobuild flavor, setup performs the first use of the real consumer's
development environment before installing `dev-exec`: `repro exec` must run a
small Bash witness command successfully. This can materialize the recipe's
declared environment and tools during setup. An unsupported command, a failure,
or success without the witness fails setup while retaining its diagnostics.
This checks the required CLI operation; it does not certify archive companions,
native Windows behavior, or warm-store reuse. Other flavors retain their own
environment path, including the existing lock-schema checks for `repro-lock`.

### Source-built Reprobuild inputs

`repro-build-pin` chooses the Reprobuild source revision.
`repro-runquota-pin` chooses its RunQuota source dependency, including the
Windows bootstrap lease daemon. Both default to `dev`; use published commit
SHAs to validate a particular source combination. The RunQuota input is also
available as `runquota-ref` on the standalone `reprobuild-provision` action.
The consumer project's lock and sibling selection are independent of these
bootstrap inputs.

The installer invokes the existing SDK source-dependency provisioner only
after selecting an explicit source build or a missing-asset fallback. Verified
release installation does not clone or build those SDK source dependencies.
Consumer-project siblings still follow `sibling-strategy` as before. This
sequencing change retains the existing override values and defaults; it does
not introduce lock-derived SDK dependency selection or qualify runtime reuse.

## Which mechanism clones the siblings

There are two, and they answer different questions:

| strategy         | reads                                                                | is the source of truth for                             |
| ---------------- | -------------------------------------------------------------------- | ------------------------------------------------------ |
| `clone-siblings` | the workspace-**project** lock in `metacraft-manifests`              | a repo **set** convenient for setting up a workspace   |
| `repro-lock`     | the consuming repo's own committed `repro.lock`, via `repro develop` | the **build's** solved dependency graph, at exact SHAs |

Project manifests are typically a superset of what a build needs. That is fine
for a human bootstrapping a workspace and wrong for CI, which is why a repo
that has a `repro.lock` should be resolving from it.

`sibling-strategy: auto` (the default) picks `repro-lock` only when **all** of:

1. `$GITHUB_WORKSPACE/repro.lock` exists and declares a solved-graph-lock schema;
2. it pins at least one **sibling** dependency (excluding `self = "true"` or the
   legacy root marker `path = "."`);
3. `env-flavor` is `reprobuild` — the one flavor where the `repro` CLI this path
   needs is installed anyway;
4. the repo declares **no** sibling list of its own (neither `siblings:` nor a
   non-empty `.github/sibling-repos`).

Otherwise it picks `clone-siblings` and names the check that failed. It is
conservative on purpose: this action is consumed at `@dev` fleet-wide, so a
caller that passes nothing keeps behaving exactly as it does today.

The decision — the value, the path taken, and the reason — is printed on one
line and added to the job summary on **every** run, including the default one.

Once the chosen path has run, `repro develop --list --json` is what decides
whether the lock is actually usable: it must exit 0, report schema
`reprobuild.develop-list.v1`, carry no errors, name a reachable `committed-lock`
backend with at least one record, and attribute **every** repo row to that
backend at a 40-hex commit SHA. A lock that names a dependency without pinning
it, or one whose pins come from a routed manifest store, is not usable.

### Forcing a path

`sibling-strategy: repro-lock` makes the committed lock authoritative and
installs the `repro` CLI under any flavor. **It never silently does nothing:**
on a repo with no usable lock it fails, naming what is missing, instead of
quietly resolving from the manifests you were trying to stop using.

`sibling-strategy: clone-siblings` pins the old behaviour for a repo that has a
`repro.lock` it is not ready to build from.

### Existing CI checkouts

The `repro-lock` path reconciles only clean, published checkouts inside the
job's owned runner layout. It preserves local work, foreign checkouts and
unpublished commits rather than resetting or deleting them. Root-repository
publication checks do not fetch or check out submodules.

A refusal reports the first rejected safety category. For local work it also
reports at most ten Git-quoted relative status/path entries, each limited to
512 characters; oversized entries are omitted whole and additional entries are
counted. It does not print configuration values, environment values or file
contents. These diagnostics identify what needs investigation; they do not
authorize bypassing the guard or cleaning the checkout automatically.

### What happens to `siblings:`

It is never silently ignored, on either path:

- under `auto`, a non-empty list keeps `clone-siblings` even when a usable lock
  exists, and the log says the lock was available and was not used. Such lists
  routinely name build-time siblings that are _not_ solved-graph dependencies —
  `reprobuild`'s own names two — and switching them to the lock would drop them;
- under a forced `repro-lock`, the lock wins and the list is reconciled against
  it: an entry the lock pins and `develop` will materialize is reported
  redundant (by name and locked revision) and dropped along with any `=ref` it
  carried. A declared source whose structured develop row is `pinned` by the
  recipe is **not** redundant: bulk develop intentionally leaves it alone.
  It is handed to the existing `clone-siblings` step as a bare repository name,
  using the committed lock's exact revision and source owner, never the
  caller's `=ref` or a branch tip. An entry the lock does not name is reported
  as outside the lock and cloned **additionally** by that same follow-on step.
  Undeclared pinned sources are not added to the clone set. A declared pinned
  alias whose selected name differs from its GitHub URL's repository basename
  refuses clearly: the existing clone interface uses one name for lock lookup
  and destination, so substituting the URL name could select another lock row. This
  pinned-source handoff also requires `lock-store: committed`; a record-store
  lookup could resolve a different SHA. Other materialized and outside-lock
  siblings retain their existing behavior.

### Relationship to `env-flavor: reprobuild`

`reprobuild-provision` and `setup-reprobuild` are not a third mechanism. They
provision _reprobuild's own_ build inputs and build the `repro` CLI;
`reprobuild-provision`'s header already documents that a **consumer** project's
dependency siblings come from `repro develop --all` against its committed
`repro.lock`. `sibling-strategy: repro-lock` is that consumer half, which is why
`auto` prefers it under this flavor — the CLI is being installed regardless.

Private locked siblings use the existing `gh-token` and `token-owner` inputs.
The shared Git-auth helper carries scoped HTTP headers in a private temporary
Git configuration only while materializing the siblings, then removes it on
success or failure. It uses `GIT_CONFIG_GLOBAL`, the supported Repro channel;
numbered invocation configuration is intentionally scrubbed by Repro's VCS operations. No token
is placed in clone URLs, process arguments or persistent checkout configuration.
The helper retains its credential-free GitHub SSH-to-HTTPS rewrites, so SSH
coordinates use the same owner-scoped headers rather than an ambient SSH key.

The `reprobuild` flavor also configures later Git CLI commands through the
same job-scoped helper as the `nix` flavor. With a nonempty `gh-token`, scoped
HTTP headers are exported through `GITHUB_ENV` as numbered Git configuration,
which ordinary commands retain through `repro exec` activation. This covers
Git CLI acquisition after sibling setup without retaining the temporary
sibling credential file or writing credentials to the runner's home. An empty
token installs no new credential; other authentication remains the caller's
responsibility. This does not configure a different build tool's internal Git
implementation or change its choice of Git transport.

When Nix is already installed, the `reprobuild` flavor also selects this job's
GitHub access token for Nix's own HTTP fetcher through the shared Nix refresh
helper. The effective map and unrelated settings are preserved; the current
token replaces `github.com` and existing prefixes for `token-owner`, retaining
other owners' separately configured credentials. An empty `gh-token` with no
effective GitHub credentials configures none; with existing GitHub credentials
it fails explicitly rather than borrowing them or erasing their scopes. Nix's
existing host-granularity compatibility is unchanged. This configures no other
transport's credential mechanism and does not install Nix, change caches or
write the runner's home configuration. The common logic runs through the
declared Actions Node runtime; legacy refresh callers receive its explicit
executable binding (or the declared Node path in the owning development shell).

## Which reprobuild store a job builds into

Where administrators have configured the shared mount, self-hosted Linux jobs
can use a **shared, persistent** reprobuild content-addressed store at
`/srv/repro-store`. The runners are ephemeral; that configured store is not.
A Linux runner label alone does not establish this wiring: the current rollout
does not cover every Linux runner, and this action does not create the mount.

Reprobuild uses that store only when `REPRO_STORE_ROOT` points at it. With the
variable unset it falls back to a per-user cache directory
(`$XDG_CACHE_HOME/repro/store`, else `$HOME/.cache/repro/store`) — which inside
a one-job-then-destroyed container is discarded along with the container.

This action now makes that choice, on every flavor, and reports it:

| what it finds at `shared-store-path` | what it does                                |
| ------------------------------------ | ------------------------------------------- |
| a writable directory                 | exports `REPRO_STORE_ROOT` to `$GITHUB_ENV` |
| nothing                              | exports nothing; **does not fail**          |
| a directory it cannot write          | exports nothing; **does not fail**          |
| `REPRO_STORE_ROOT` already set       | leaves the caller's value alone             |

The two "exports nothing" rows also apply to Linux jobs without a configured
shared mount. The supported per-user fallback lets setup run across runner
classes without making an absent optimisation a setup failure. Successful setup
therefore does not prove that host storage is wired into a guest or that two
jobs reused it. Missing sharing can remain a deployment defect even while the
fallback works correctly; deployment and cross-job reuse need their own proof.

Writability is checked with a **real write**, not with `-w`. The store is shared
between per-job containers and is therefore world-writable, and it is bounded by
a quota, so `-w` reports yes for a store that is full. The probe creates and
immediately removes a dotfile at the store root; a dotfile is not the shape of a
store entry, and the suite asserts the store is left empty. An already-populated
store is additionally checked for a writable `index.db` — the root of a shared
mount is world-writable by construction, while the index belongs to whichever
job reached the mount first, and that is the one remaining way a store could
pass the root probe and then fail inside a build.

The decision is printed on one line and added to the job summary on **every**
run, including the ones that export nothing. The gap this closes went unnoticed
for months precisely because nothing ever printed a store root.

`shared-store-path: ""` switches the probe off entirely.

## Sibling-repo overrides

For workflows that pre-clone sibling repos alongside the host
checkout (see [clone-repo](../clone-repo/)) and want the dev
shell to consume them via `--override-input`:

```yaml
- uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
  with:
    repo: metacraft-labs/codetracer-trace-format
    path: ${{ github.workspace }}/../codetracer-trace-format
    gh-token: ${{ secrets.GITHUB_TOKEN }}
- uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
  with:
    env-flavor: nix
    gh-token: ${{ secrets.GITHUB_TOKEN }}
    flake-override-inputs: |
      codetracer-trace-format=../codetracer-trace-format
- run: dev-exec just test
```

## Reprobuild compatibility

Windows reprobuild setup prints a small SDK receipt after its real `repro exec`
witness. It fingerprints the resolved public CLI, the selected installation's
engine and RunQuota files, and shipped source markers. It also records inherited
`WINDOWS_DIY_SKIP_*` and `WINDOWS_DIY_ENSURE_*` controls, including set-empty values,
without dumping the job environment. Missing files stay explicitly missing.
Installed daemon bytes do not establish which daemon served a lease; the receipt
does not qualify native ARM execution or shared-store reuse.

The receipt also observes the process serving the selected Windows RunQuota
endpoint. It uses the client's `RUNQUOTA_SOCKET` selection, including the default
and the existing named-pipe mapping, and holds the pipe and query-only process
handles while recording the server process ID, creation time, kernel-reported
image path and the hash of the file at that path. It sends no protocol request,
starts or stops no daemon, and changes no SDK selection. Missing, busy,
inaccessible or changing identities remain explicitly unknown, without recovery
or a fallback to the installed daemon. This is an endpoint observation at that
instant, not attribution of earlier or later leases, a memory-image hash, or a
complete compiled-source attestation.

For `env-flavor: reprobuild`, `dev-exec` preserves the generic
`repro exec -- <cmd>` contract for arbitrary commands. The environment is
the consumer project selected during setup, including when a later step has
a nested `working-directory`. The wrapper binds that project explicitly and
runs the command in the caller's original directory, preserving argument
boundaries and its exit status. It does not select a different environment
from the later step's directory or move a relative command/input to the
project root. As a compatibility
shim for newer typed tool provisioning requirements, calls shaped as
`dev-exec repro build ...` or `dev-exec repro test ...` automatically get
`--tool-provisioning=path` appended unless the command already includes a
`--tool-provisioning=...` flag.

Each reprobuild wrapper installation, its project binding and its child
helpers live in a unique directory under the job's `RUNNER_TEMP`, published
through `GITHUB_PATH`. Another setup or runner sharing the same home cannot
replace the earlier installation's selected project.

### Wrapper contract tests

The existing `test.yml` workflow enrolls the real wrapper contract on Linux
and native Windows using the verified `v0.2.17` release installer. A missing
baseline fails the test; it does not build an SDK or skip the contract.
Windows executes the generated Bash, PowerShell and CMD wrappers and the
existing native CMD status controls. Linux results do not qualify Windows.

Local real-engine integration is explicit: `tools/lint.sh --repro
/absolute/path/to/measured/repro` includes the nested-directory regression.
The ordinary no-argument lint does not infer or download an SDK. The explicit
mode fails if its CLI is absent or unusable. For focused execution, run
`python3 setup-dev-env/test-repro-wrapper-cwd.py --repro <qualified-cli>
--report <result.json>`; the report retains the actual platform and streams.

## Forbidden patterns in calling workflows

The contract documented in
[ci-shared-dev-env.md](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/ci-shared-dev-env.md)
forbids:

- Installing tools the build needs directly in the workflow YAML
  (`apt-get install capnproto`, `choco install nim`,
  `nimble install -y stew`, `cargo install …`). Add them to the
  project's dev env declaration (`flake.nix` devShell,
  `env.ps1`, `reprobuild.toml`) and CI will re-use them through
  `dev-exec`.
- Calling `cargo`, `nim`, `python`, etc. directly outside
  `dev-exec`. Every build/test step must go through it so the
  CI invocation matches local dev exactly.

A repo that needs a tool not in its dev env declaration should
add the tool to the declaration in the same PR that introduces
the CI use — not as a CI YAML one-off.
