# The tool pins as one attribute set keyed by tool name: the parsed contents
# of every pins/<tool>.json, plus `flakeRef`, the locked flake reference of the
# pinned revision. Reading it fetches nothing; see README.md.
let
  files = builtins.filter (
    name: builtins.match ".*\\.json" name != null && name != "pin.schema.json"
  ) (builtins.attrNames (builtins.readDir ./.));
  read =
    file:
    let
      pin = builtins.fromJSON (builtins.readFile (./. + "/${file}"));
    in
    {
      name = pin.tool;
      value = pin // {
        flakeRef = "github:${pin.owner}/${pin.repo}/${pin.rev}?narHash=${pin.narHash}";
      };
    };
in
builtins.listToAttrs (map read files)
