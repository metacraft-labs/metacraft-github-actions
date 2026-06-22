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
