# Tooling pins

One JSON file per tool: the revision of each real tool that infra, the
dotfiles and CI consume. `pin.schema.json` is the format (schema 1, unknown
fields rejected). Plain JSON on purpose: Nix reads it with `builtins.fromJSON`
without evaluating this repository, shell with `jq`, Windows with
`ConvertFrom-Json`.

Read from Nix:

```nix
let
  p = builtins.fromJSON (builtins.readFile (actions + "/pins/agent-harbor.json"));
  src = builtins.getFlake "github:${p.owner}/${p.repo}/${p.rev}?narHash=${p.narHash}";
in
src.packages.${system}.${p.attrs.ah}
```

Read from shell: `jq -r '.rev, .narHash' pins/agent-harbor.json`.

Bump with `tools/update-pin.sh <tool> <rev>`: it rewrites `rev` and `narHash`
and nothing else. A bump is a deploy for every consumer that follows the pin,
so it needs a review by the consuming repository's owners.

`tools/check-pins.py` validates every file against the schema and that `tool`
equals the file name. With `--remote` it also checks that the revision exists,
that the fetched tree matches `narHash`, and that each `attrs` value is a
package of the flake. The `pins` workflow runs both, the remote part only on
pushes and same-repository pull requests, because it needs a token that fork
pull requests never receive.
