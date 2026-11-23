# metacraft-github-actions

Shared GitHub Actions for metacraft-labs projects

## Tool pins

[`pins/`](pins/README.md) holds the organisation's one pin of each real tool:
`pins/reprobuild.json`, `pins/agent-harbor.json` and, where it is used,
CodeTracer. `setup-reprobuild` and `setup-dev-env` install the Reprobuild pin
by default, and Nix consumers read the pins through this repository's flake
output `pins`. A change to a pin is gated by the `pins-gate` check.

## Reprobuild provisioning mode

For `dev-exec repro build` and `dev-exec repro test`, an explicit
`--tool-provisioning` argument passes unchanged; otherwise Repro uses
`REPRO_TOOL_PROVISIONING` when set, else the project's declared default. On a
NixOS runner, `setup-dev-env` exports `REPRO_TOOL_PROVISIONING=nix` unless the
job already set it, because NixOS cannot run the generic-Linux tool tarballs
the other modes fall back to. The wrapper does not select PATH mode. It runs
these commands inside the project's environment, as a developer does, so a
`path`-mode tool comes from that environment's `PATH`. It adds
`--daemon=off` only when no daemon selector is supplied. Generic commands retain
the setup project's environment, the caller's working directory and child status.
Projects declare their platform-specific tool realizations in `repro.nim`, rather
than installing tools or rewriting PATH in their workflows.

## Prepare inputs before long running gates

[`prepare-repro-envs`](prepare-repro-envs/README.md) enters the caller's existing
SDK shell and activates each later project's normal Repro environment while
credentials are valid. Bootstrap and activation refusals are infrastructure
failures, with the SDK's original diagnostic and status preserved. It selects
no compiler, provisioning mode or package pin.

## Release tools

`.github/workflows/release-tools.yml` builds the caller's declared target
inventory, verifies transferred artifacts, and publishes only tag-triggered
releases with a successful dry run for the same source commit. Dispatches are
dry runs. Product build and smoke-test scripts remain in the caller.

Planning, assembly and publication use the shared `CI_RUNNER_MODE` selector:
standard `ubuntu-24.04` when hosted is selected, otherwise the exact
`eph-linux-x64-release` scale-set route. A POSIX target may declare
`hostedRunner` alongside its existing `runner`; the planner uses that alternative
only when the selector chose hosted. Allowed alternatives are Linux x64 on
`ubuntu-24.04` and macOS ARM64 on `macos-26`. Each requires `runnerMigration`
with the exact source version, a nonempty owner and a `followup` tracking ID:
the dated slug of the internal issue that owns the migration, such as
`2026-09-24-example-runner-migration`. URLs are rejected, so a public release
spec never names where the tracker lives.
The planner rejects expired or incomplete exceptions even on the fallback route.
Existing Linux/Windows ARM64 migration entries keep their explicit native routes.

The first-release scope and migration ownership are tracked internally.
Runner selection does not change artifact membership, signatures, installer
checks, Linux portability checks or publication requirements.

## `evict-stale-git-credentials`

Removes credential-bearing keys (`http.*.extraheader`, `url.*x-access-token*`)
from a reused self-hosted runner's `~/.gitconfig`. Run it as a job's first
step, before `actions/checkout`: a stale owner-scoped `extraHeader` there
outranks checkout's fresh one and makes checkout fail with "could not read
Username". It is a remote action because it has to be on disk before any git
operation runs, and the runner downloads actions without git. Pin it by SHA:

```yaml
- uses: metacraft-labs/metacraft-github-actions/evict-stale-git-credentials@<sha>
```

## `git-auth`

Runs a bash script with the job's scoped GitHub credential, delivered through
a private `GIT_CONFIG_GLOBAL` file. Use it for any step whose Git access goes
through Repro, such as `repro develop` cloning a private sibling.

`setup-nix` exports the job credential as numbered Git configuration
(`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`, `GIT_CONFIG_VALUE_n`). Plain `git`
reads it. Repro deliberately removes numbered configuration from the Git
commands it runs for another repository, so in the same job `git ls-remote`
succeeds and `repro develop` fails with `could not read Username for
'https://github.com'`. Git reads a global configuration file named by
`GIT_CONFIG_GLOBAL` through that boundary.

```yaml
- uses: metacraft-labs/metacraft-github-actions/git-auth@<sha>
  with:
    gh-token: ${{ steps.ci_token.outputs.token }}
    working-directory: ${{ github.workspace }}
    run: |
      nix develop .#ci --command repro develop --all --reset --into=..
```

| Input               | Default          | Meaning                                                            |
| ------------------- | ---------------- | ------------------------------------------------------------------ |
| `gh-token`          | (required)       | The job's token. An empty value fails the step.                    |
| `token-owner`       | `metacraft-labs` | Whitespace-separated owners the credential is scoped to.           |
| `working-directory` | `.`              | Directory the script runs in.                                      |
| `run`               | (required)       | The script. It runs under `bash -eo pipefail`, like a `run:` step. |

The action writes an owner-scoped `http.<url>.extraHeader`, and the ssh-to-https
`insteadOf` rewrites that carry no credential, to a `0600` file in a private
directory under `RUNNER_TEMP`. It then sets `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_NOSYSTEM=1`, clears the inherited numbered configuration, runs the
script, and deletes the file however the script exits. The token is not put in
a URL, an argument list, a checkout or a persistent configuration file.
`GH_TOKEN` is not exported to the script, and the derived header is printed
only as an `::add-mask::` command. The credential logic is the same
`scoped-git-auth.sh` that `setup-nix`, `clone-siblings` and `setup-dev-env`
use.

An empty `gh-token` is an error, not an anonymous run. A private clone without a
credential fails later, as a 404 or a username prompt that does not name the
missing token.

The step needs only Bash and coreutils on the runner's `PATH`, so it runs on
nix-darwin runners before any dev shell. Its contract suite is
`git-auth/test-private-global-config.py`. Run it with `--repro <cli>` to add
the real `repro develop` cases, including the control that shows numbered
configuration alone does not reach Repro's clone.

## `assert-workflow-triggers`

Fails when a workflow's `push` / `pull_request` branch filters do not name the
branch the repository actually merges into.

A filter naming a branch the repository does not have is not an error. It
produces no run, silently and permanently, and an empty check list on a
mainline commit looks exactly like a clean one. This repository's own
`test.yml` said `branches: [main]` while its mainline was `dev`; a sweep
afterwards found the same defect in 33 workflows across 22 repositories.

Add it to any workflow that already checks the repository out:

```yaml
- uses: metacraft-labs/metacraft-github-actions/assert-workflow-triggers@dev
```

The action declares a Node 24 runtime and passes that executable to its
filesystem helpers. Only Bash is required on the caller's `PATH` when the
mainline is explicit; automatic mainline detection also needs Git. The filter
scanner uses Bash builtins, and Node finishes each file read before scanning
or exempting it. Failed reads or origin listings are errors even if they have
produced partial output. No tools or packages are downloaded by the action.
The direct shell command requires Node 20 or 24 for file I/O (provided by this
repository's `shell.nix`), or an explicit executable in `WORKFLOW_TRIGGERS_NODE`.

The optional `workflows` input retains Bash word splitting and pathname
expansion in the caller's working directory. An empty input discovers both
workflow suffixes in the caller's `.github/workflows` directory. Input text is
never evaluated as shell code. Failed or empty enumeration is an error, even
when an incomplete enumeration has already emitted a valid filename.

The mainline is detected from the branches that exist on `origin`, in
[branching-policy](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/branching-policy.md)
order — `dev`, then `latest`, then `live`. Detection has no `main` fallback: a
repository that has not migrated has nothing to enforce, and guessing `main`
would be the very assumption the guard exists to catch. Product-adapted forks,
whose mainline is a product name, state it:

```yaml
- uses: metacraft-labs/metacraft-github-actions/assert-workflow-triggers@dev
  with:
    mainline: codetracer
```

Workflows filtered only by `tags:` are release triggers, not branch triggers,
and pass unchanged. A workflow that genuinely must not run on the mainline —
a deploy belonging to one environment branch — says so in the file, with a
reason, which is checked for and cannot be left blank:

```yaml
# ci-mainline-exempt: deploys the hosted app; `cloud` is the deploy branch
```

## `refresh-workspace-lock`

Moves a stale sibling pin in a **record store**, and is the only thing in this
repository that can.

> **Record-store projects only.** By default a repo's sibling pins live in its
> committed `repro.lock` (`clone-siblings` / `setup-dev-env` `lock-store:
committed`), and moving one is an ordinary commit: `repro lock refresh` in the
> repo inside its workspace, then commit the lock. This action, and
> `publish-workspace-lock`, matter only for a project that opted into a team
> record store with `lock-store: record-store`
> (reprobuild-specs/Unified-Locking-And-Hooks.md §14).
>
> **`publish-workspace-lock` has no caller.** Every per-repo
> `publish-workspace-lock.yml` called it without `lock-store`, so under the
> default it published nothing (§14.6: a committed lock travels with the merge
> commit, so there is nothing to re-anchor), and those workflows are being
> removed (from 2026-10-14). The action is kept only for a project that opts into a record
> store; such a project adds a caller that passes `lock-store: record-store`.

A workspace lock record is keyed by a commit of the repo it describes, and it is
generated by that repo's local pre-push gate from a workspace that actually
existed. `publish-workspace-lock` then _carries_ that record onto each mainline
commit: every sibling pin copied verbatim, precisely one field changed. That
carry is correct and must not refresh — a refreshed pin would state a fact about
a workspace nobody ever had, and a fabricated lock succeeds silently where a
missing one fails loudly with a named remedy.

The consequence is that a pin only moves when a _new_ commit gets a lock
generated in a workspace where the sibling is newer. Without that, a repo locked
months ago re-anchors the same stale pin onto every future push, and a fix
landed in a sibling never reaches its cross-repo CI.

So this action materialises nothing by itself: it is handed a real workspace,
runs the real `repro ws lock` in it, and proposes the result as a **pull
request** — so the refreshed composition is _built by that pull request's own
CI_ before anything is published, and the existing carry propagates it from the
merge onward.

It never writes a lock. It runs the generator and carries what the generator
wrote, or it refuses and says why. In particular it refuses a changed lock whose
`[lock] created_at` does not show that _this run_ produced it, so a dirty
checkout cannot become a published record under its name.

**The dry run is the default.** It reports every pin that would move and then
restores the checkout to the bytes it found, so it can be scheduled on a busy
fleet and still be informative.

A per-repo caller. The workspace has to exist before this step: on a runner
that keeps one, point `workspace-root` at it; otherwise materialise it first
(`repro workspace init metacraft-labs`) and point at that.

```yaml
name: refresh workspace lock

on:
  schedule:
    - cron: "17 4 * * 1"
  workflow_dispatch:
    inputs:
      dry-run:
        description: "false opens a proposal branch"
        default: "true"

# ci-mainline-exempt: scheduled maintenance; it proposes a branch and never
# runs on a mainline push.

jobs:
  refresh:
    # A private repo cannot use a GitHub-hosted runner in this org, and this job
    # needs a workspace on disk in any case.
    runs-on: [self-hosted, linux, X64]
    steps:
      - uses: actions/checkout@v5
        with:
          persist-credentials: false

      - id: ci_token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ vars.CI_TOKEN_PROVIDER_APP_ID }}
          private-key: ${{ secrets.CI_TOKEN_PROVIDER_PRIVATE_KEY }}
          owner: metacraft-labs

      - uses: metacraft-labs/metacraft-github-actions/refresh-workspace-lock@dev
        with:
          gh-token: ${{ steps.ci_token.outputs.token }}
          workspace-root: ${{ runner.temp }}/ws
          # Leave this at its default until the schedule has produced a few
          # dry runs you agree with.
          dry-run: "true"
```

Outputs: `status` (`unchanged`, `would-refresh`, `refreshed`, `refused`),
`changed`, and `branch`.

## The CodeTracer pin and its Apple Silicon lock

`pins/codetracer.json` is the one CodeTracer revision that other repositories
consume: blocktracer's embedded SDK, reprobuild's `codetracer-src` and the
dotfiles' `codetracer` input. The pin format is in `pins/README.md`.
CodeTracer itself is not a consumer. Its own flake keeps its own independently
locked Reprobuild cohort, and nothing here changes that.

The first pin is `a7cddd8bce554f5d73a7636e2bad15605b71963c`, a commit on
CodeTracer `dev` (`"kind": "dev-commit"`). Its `narHash` is what
`nix flake prefetch github:metacraft-labs/codetracer/<rev> --json` reports.
A `github:` tree has no submodules, so a consumer that needs CodeTracer's
submodules must fetch them separately.

The pin is not `a3986b0de1`, the revision blocktracer built against. That
revision's `repro.lock` pins `codetracer-image-diff` at `e002498eac`, a commit
that no longer exists on GitHub after that repository's history was rewritten.
CodeTracer `c2481fc45` repinned it. The macOS job failed on `a3986b0de1` while
it was provisioning the siblings, before the solve, so the gate could never
pass with that revision.

CodeTracer commits two solves: `repro.lock` (amd64-linux) and
`locks/arm64-macosx.lock`. Reprobuild solves a lock only for the platform it
runs on, so the darwin lock can be produced only on an Apple Silicon host. The
reusable workflow `.github/workflows/codetracer-mac-lock.yml` does that on a
GitHub-hosted arm64 macOS runner (`macos-26`), never on a fleet Mac. The `pins`
workflow calls it only when `pins/codetracer.json`, the workflow or
`tools/codetracer-mac-lock.py` changed. It runs three jobs:

1. `plan` runs on Linux with no secrets. It refuses a malformed revision, and
   one that does not exist or has no `locks/arm64-macosx.lock`. It also reads
   the Reprobuild revision that CodeTracer's own `flake.lock` pins.
2. `solve` runs on macOS:
   - It builds that Reprobuild exactly as CodeTracer's dev shell does, as the
     `reprobuild` input of `builtins.getFlake "github:metacraft-labs/codetracer/<rev>"`.
     It also takes the `reprobuild-packages` catalog that shell exports.
   - It puts every sibling at `repro.lock`'s revisions with
     `repro develop --all --reset`. Some of those siblings are private, so the
     clones are authenticated with a CI token provider token passed through
     `git-auth/scoped-git-auth.sh`.
   - It runs
     `repro lock refresh . --lock locks/arm64-macosx.lock --platform=arm64-macosx`.
   - It checks the result: the platform is `arm64-macosx`, every dependency
     revision equals `repro.lock`'s, and `reprobuild` and `reprobuild-packages`
     equal `flake.lock`'s. When the revision carries CodeTracer's own
     `scripts/check-platform-lock-pins.sh`, it runs that as well.
   - It uploads the solved lock, the committed lock, the log and `result.json`
     as the artifact `codetracer-arm64-macosx-lock-<rev>`.
3. `result` always runs and reports one of these outcomes:
   - `confirmed`: the solve equals the committed darwin lock, apart from its
     `self` entry.
   - `produced`: the solve differs. The artifact is the new lock.
   - `unsolvable`, `failed-checks`, `invalid-pin` or `failed`.
   - `skipped`: no credentials were available, as in a fork's pull request.
     Nothing was verified, so it fails too.

   `confirmed` and `produced` pass. Every other outcome fails. This job
   never pushes to CodeTracer. A produced lock reaches CodeTracer only through
   CodeTracer's own process.

To bump the pin:

1. Pick a commit on CodeTracer `dev`.
2. Rewrite `rev` and `narHash` (the prefetch command above). Change nothing
   else.
3. Open a pull request. The pins gate runs the macOS solve.
4. If the outcome is `produced`, commit the artifact's `arm64-macosx.lock` to
   CodeTracer as `locks/arm64-macosx.lock` through a CodeTracer pull request.
   Do this before the consumers move.

A bump is a deploy for every consumer, so it needs a review from the consuming
repositories' owners.

To run the solve by hand, use **Actions → codetracer-mac-lock → Run workflow**:

- With `rev` set, it solves any CodeTracer commit.
- With `expect: fail` and `negative-control: true`, it is the negative
  control. `"bash <4"` is added after the siblings are provisioned, next to
  the `"bash >=4"` CodeTracer declares. The run passes only if
  `repro lock refresh` answers UNSAT (exit 3, `solver UNSAT`). Any other
  failure does not count, including one in provisioning or the engine build.
  A floor alone such as `"bash >=99999"` would not work as a control: the
  solver grounds a constraint with no upper bound at its floor, so that
  constraint solves.

The Linux half of the tool is tested by `python3 -I tools/test-codetracer-mac-lock.py`,
which `tools/lint.sh` and the `test` workflow both run.

## Contributor hooks on POSIX

Authorize the repository-local pinned SDK with `direnv allow`, then run commands
through `direnv exec . <command>`.
It supplies native Python, UV and Prek; the committed configuration requires
system Python and the canonical upstream checker execution path.

Select a measured Repro build. When changing the servicing engine, first run
`direnv exec . /absolute/path/to/repro hooks ensure --vcs .` to reconcile the
owning managed hooks normally. Then install the portable hook with
`direnv exec . python3 tools/install-canonical-hooks.py --repro /absolute/path/to/repro`.
The installer verifies its generated contract with that same selected engine;
a version string or dispatcher protocol alone does not establish a match.
It deliberately preserves the existing pre-push bytes, so an engine change
belongs in the preceding canonical reconciliation. It refuses unknown local
hooks, external hook paths and mismatched generated bodies.
Run `direnv exec . prek run --all-files` and the unchanged test workflow commands.
Native Windows formatter/tool provisioning remains an open qualification gap.

The additional real-engine hook integration controls are part of required local
qualification. Run `direnv exec . bash tools/lint.sh --repro /absolute/path/to/repro`
with the same measured servicing engine. This runs all five generated-hook
cases after the unchanged lint checks. They currently run locally, not in CI;
the no-argument CI lint does not acquire or guess a Repro engine.
