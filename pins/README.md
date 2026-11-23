# Tooling pins

One JSON file per tool: the revision of each real tool that CI, infra, the
dotfiles, devops-modules and the workspace dev shells consume. Each tool has
exactly one pin, here, and no consumer keeps a revision of its own.

| File                          | Tool                                                       | Owner                                         |
| ----------------------------- | ---------------------------------------------------------- | --------------------------------------------- |
| `reprobuild.json`             | Reprobuild (`repro`); the default of `setup-reprobuild`    | Single-Tool-Pins (metacraft-pm `milestones/`) |
| `agent-harbor.json`           | Agent Harbor                                               | agent-upgrades                                |
| `agent-harbor-llm-proxy.json` | Agent Harbor's LLM proxy                                   | agent-upgrades                                |
| `codetracer.json`             | CodeTracer, where other repositories use it (not yet here) | Single-Tool-Pins STP3                         |

## Format

`pin.schema.json` is the format: schema 1, unknown fields rejected. Plain JSON
on purpose: Nix reads it with `builtins.fromJSON` without evaluating this
repository, shell with `jq`, Windows with `ConvertFrom-Json`.

| Field     | Type                                         | Required | Meaning                                                                                   |
| --------- | -------------------------------------------- | -------- | ----------------------------------------------------------------------------------------- |
| `schema`  | integer `1`                                  | yes      | Format version. A reader refuses any other value.                                         |
| `tool`    | string                                       | yes      | The file name without `.json`.                                                            |
| `owner`   | string                                       | yes      | GitHub owner of the source repository.                                                    |
| `repo`    | string                                       | yes      | GitHub repository name.                                                                   |
| `rev`     | string, 40 lowercase hex                     | yes      | Full commit SHA. Never a branch, a tag name or a tag object's SHA.                        |
| `narHash` | string, SRI `sha256-…`                       | yes      | Hash of the fetched tree, as `nix flake prefetch` reports it.                             |
| `flake`   | boolean                                      | no       | `false` when the tree is not a flake. Default `true`.                                     |
| `systems` | array of system names                        | no       | Systems on which every `attrs` value must exist. Default x86_64-linux and aarch64-darwin. |
| `attrs`   | object, string values                        | no       | Tool-specific role to package attribute name in the flake's `packages.<system>`.          |
| `version` | string, `X.Y.Z[-+…]`                         | no       | The version the tool reports for `rev`. Given together with `kind`.                       |
| `kind`    | `dev-commit` \| `agents-commit` \| `release` | no       | Why `rev` may be pinned. Given together with `version`.                                   |

`kind` is the rule of metacraft-pm
`how-to-distribute-new-reprobuild-versions-internally.md`, "Which revision may
be pinned": `rev` must be immutable and published, which means one of

- `dev-commit`: an ancestor of the repository's `dev`;
- `agents-commit`: an ancestor of its `agents`;
- `release`: the commit of the annotated tag `v<version>`, whose GitHub release
  exists and is not a draft.

The Reprobuild pin must carry both `version` and `kind`, because
`setup-reprobuild` installs by them. The first one is v0.2.34, commit
`d1bf1f065aca01b90c3bbdddc57d14e977f49e1a`: a commit on reprobuild `agents`
(the tag `v0.2.34` has no GitHub release, so it is `agents-commit`, not
`release`).

## Reading a pin

### From Nix

This repository's flake has no inputs and one output, `pins`: every pin
parsed, plus `flakeRef`, the locked flake reference of its revision. Reading it
fetches nothing. A consumer takes this repository as one input:

```nix
{
  inputs.metacraft-github-actions.url = "github:metacraft-labs/metacraft-github-actions/dev";

  outputs = { self, metacraft-github-actions, ... }:
    let
      pin = metacraft-github-actions.pins.reprobuild;
      # pin.flakeRef is
      # "github:metacraft-labs/reprobuild/<rev>?narHash=<narHash>"
      reprobuild = builtins.getFlake pin.flakeRef;
    in
    { /* reprobuild.packages.${system}.${pin.attrs.repro} */ };
}
```

The same without the flake output, with the input declared `flake = false`:

```nix
let
  p = builtins.fromJSON (builtins.readFile "${metacraft-github-actions}/pins/reprobuild.json");
  src = builtins.getFlake "github:${p.owner}/${p.repo}/${p.rev}?narHash=${p.narHash}";
in
src.packages.${system}.${p.attrs.repro}
```

`builtins.getFlake` accepts that reference in pure evaluation, because the
`rev` and `narHash` lock it; a wrong `narHash` fails with `NAR hash mismatch`.
A flake input's `url` cannot be computed from another input, so the pinned tool
is reached through `getFlake` as above, not declared as an input of its own.

### From the setup actions

`setup-reprobuild` and `setup-dev-env` read `reprobuild.json` from their own
checkout (`setup-reprobuild/resolve-reprobuild-pin.sh`; on Windows through
`read-pin.ps1` and `ConvertFrom-Json`). With no `repro-build-pin` and no
`repro-version`, they install the pin: a `dev-commit` or `agents-commit` pin is
built from source at `rev`, a `release` pin is installed from its prebuilt
archive. Afterwards the installed `repro --version` must report `version`, and
a source build must be at `rev`. `repro-build-pin` and `repro-version` remain
as explicit overrides only.

### From shell

`jq -r '.rev, .narHash' pins/agent-harbor.json`.

## Moving a pin

Bump with `tools/update-pin.sh <tool> <rev>`: it rewrites `rev` and `narHash`
and nothing else; update `version` and `kind` by hand when the tool has them.
A bump is a deploy for every consumer that follows the pin, so it needs a
review by the consuming repository's owners. Bump commits and pull requests
name the revision and its kind, for example "v0.2.34 (commit on agents; tag
without a release)".

## The gate

The `pins` workflow (`.github/workflows/pins.yml`) runs on every pull request
and push. Its job **`pins-gate`** is the required check; it always reports,
and passes trivially when a change touches no pin and none of the readers.

- `tools/check-pins.py` validates every file against the schema and that
  `tool` equals the file name, on every run. With `--remote` it also checks
  that `rev` exists, that the fetched tree matches `narHash`, that each `attrs`
  value is a package of the flake, and that `rev` qualifies as its `kind`. A
  negative control shows that a pin naming a nonexistent commit fails.
- For the Reprobuild pin it runs sections 0 and 0b of the distribution guide:
  the pinned package, read through the flake output `pins` (which must agree
  with the JSON file), builds on Linux and macOS, and the binary reads the real
  workspace manifests (metacraft-labs/repro-workspace `agents` and `dev`) and
  answers the managed-hook contract of the hooks it generates
  (`tools/check-reprobuild-fits-workspace.sh`).
- It runs `setup-reprobuild` on Linux, macOS and Windows with no override,
  and with a release and a source-revision override.
