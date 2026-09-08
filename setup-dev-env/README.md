# setup-dev-env

CI-side replay of the repository's deterministic dev environment.

After this composite action runs, subsequent steps invoke
`dev-exec <cmd>` to execute any command inside the same env that
a developer uses locally:

| flavor        | `dev-exec <cmd>` resolves to                |
| ------------- | ------------------------------------------- |
| `nix`         | `nix develop [--override-input …] -c <cmd>` |
| `windows-diy` | `<cmd>` (env from `env.ps1` already loaded) |
| `reprobuild`  | `repro exec -- <cmd>`                       |

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
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@main
        with:
          env-flavor: ${{ matrix.env }}
          gh-token: ${{ secrets.GITHUB_TOKEN }}
      - run: dev-exec just test
```

## Inputs

| Input                   | Required | Description                                                                                                                                                                  |
| ----------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `env-flavor`            | yes      | `nix` \| `windows-diy` \| `reprobuild`.                                                                                                                                      |
| `gh-token`              | no       | Forwarded to `setup-nix` so private flake inputs resolve.                                                                                                                    |
| `substituters`          | no       | Space-separated extra Nix substituter URLs, such as Attic cache URLs.                                                                                                        |
| `trusted-public-keys`   | no       | Space-separated signing keys for the extra substituters.                                                                                                                     |
| `flake-override-inputs` | no       | Newline-separated `NAME=PATH` entries; each becomes `--override-input NAME path:PATH` on every `nix develop` invocation. Use for sibling-repo overrides cloned alongside.    |
| `env-ps1-path`          | no       | Path to `env.ps1` (windows-diy only). Defaults to `./env.ps1`.                                                                                                               |
| `sibling-strategy`      | no       | `auto` (default) \| `repro-lock` \| `clone-siblings`. Which mechanism provisions cross-repo siblings — see below.                                                             |
| `siblings`              | no       | Whitespace/newline-separated sibling list, overriding `.github/sibling-repos`. Reconciled against `repro.lock` on the repro path — see below.                                 |
| `shared-store-path`     | no       | Where a shared, persistent reprobuild store is expected to be mounted. Defaults to `/srv/repro-store`; empty switches the probe off. See below.                               |

## Which mechanism clones the siblings

There are two, and they answer different questions:

| strategy         | reads                                                                  | is the source of truth for                            |
| ---------------- | ---------------------------------------------------------------------- | ----------------------------------------------------- |
| `clone-siblings` | the workspace-**project** lock in `metacraft-manifests`                | a repo **set** convenient for setting up a workspace  |
| `repro-lock`     | the consuming repo's own committed `repro.lock`, via `repro develop`   | the **build's** solved dependency graph, at exact SHAs |

Project manifests are typically a superset of what a build needs. That is fine
for a human bootstrapping a workspace and wrong for CI, which is why a repo
that has a `repro.lock` should be resolving from it.

`sibling-strategy: auto` (the default) picks `repro-lock` only when **all** of:

1. `$GITHUB_WORKSPACE/repro.lock` exists and declares a solved-graph-lock schema;
2. it pins at least one **sibling** dependency (a dep whose `path` is not `"."`);
3. `env-flavor` is `reprobuild` — the one flavor where the `repro` CLI this path
   needs is installed anyway;
4. the repo declares **no** sibling list of its own (neither `siblings:` nor a
   non-empty `.github/sibling-repos`).

Otherwise it picks `clone-siblings` and names the check that failed. It is
conservative on purpose: this action is consumed at `@main` fleet-wide, so a
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

### What happens to `siblings:`

It is never silently ignored, on either path:

- under `auto`, a non-empty list keeps `clone-siblings` even when a usable lock
  exists, and the log says the lock was available and was not used. Such lists
  routinely name build-time siblings that are *not* solved-graph dependencies —
  `reprobuild`'s own names two — and switching them to the lock would drop them;
- under a forced `repro-lock`, the lock wins and the list is reconciled against
  it: an entry the lock already pins is reported redundant (by name and locked
  revision) and dropped along with any `=ref` it carried; an entry the lock does
  not name is reported as outside the lock and cloned **additionally** by a
  follow-on `clone-siblings` step.

### Relationship to `env-flavor: reprobuild`

`reprobuild-provision` and `setup-reprobuild` are not a third mechanism. They
provision *reprobuild's own* build inputs and build the `repro` CLI;
`reprobuild-provision`'s header already documents that a **consumer** project's
dependency siblings come from `repro develop --all` against its committed
`repro.lock`. `sibling-strategy: repro-lock` is that consumer half, which is why
`auto` prefers it under this flavor — the CLI is being installed regardless.

## Which reprobuild store a job builds into

The self-hosted Linux runners mount a **shared, persistent** reprobuild
content-addressed store into every per-job container, at `/srv/repro-store`.
The runners are ephemeral; the store is not, so an artefact realised by one job
is meant to still be there for the next.

Reprobuild uses that store only when `REPRO_STORE_ROOT` points at it. With the
variable unset it falls back to a per-user cache directory
(`$XDG_CACHE_HOME/repro/store`, else `$HOME/.cache/repro/store`) — which inside
a one-job-then-destroyed container is discarded along with the container.

This action now makes that choice, on every flavor, and reports it:

| what it finds at `shared-store-path`   | what it does                    |
| -------------------------------------- | ------------------------------- |
| a writable directory                   | exports `REPRO_STORE_ROOT` to `$GITHUB_ENV` |
| nothing                                | exports nothing; **does not fail** |
| a directory it cannot write            | exports nothing; **does not fail** |
| `REPRO_STORE_ROOT` already set         | leaves the caller's value alone |

The two "exports nothing" rows are why this is safe to run fleet-wide: on
GitHub-hosted runners, on macOS and on Windows there is no such mount, and
falling back to the per-user default is not a degraded state — it is what every
runner without a shared store already does. Turning a missing optimisation into
a red build would take out the whole fleet the first time a mount was renamed.

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
- uses: metacraft-labs/metacraft-github-actions/clone-repo@main
  with:
    repo: metacraft-labs/codetracer-trace-format
    path: ${{ github.workspace }}/../codetracer-trace-format
    gh-token: ${{ secrets.GITHUB_TOKEN }}
- uses: metacraft-labs/metacraft-github-actions/setup-dev-env@main
  with:
    env-flavor: nix
    gh-token: ${{ secrets.GITHUB_TOKEN }}
    flake-override-inputs: |
      codetracer-trace-format=../codetracer-trace-format
- run: dev-exec just test
```

## Reprobuild compatibility

For `env-flavor: reprobuild`, `dev-exec` preserves the generic
`repro exec -- <cmd>` contract for arbitrary commands. As a compatibility
shim for newer typed tool provisioning requirements, calls shaped as
`dev-exec repro build ...` or `dev-exec repro test ...` automatically get
`--tool-provisioning=path` appended unless the command already includes a
`--tool-provisioning=...` flag.

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
