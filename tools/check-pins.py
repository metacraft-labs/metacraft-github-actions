#!/usr/bin/env python3
"""Validate the tooling pins under pins/.

Local checks (always, standard library only, no network):
  1. every pins/*.json parses and satisfies pins/pin.schema.json;
  2. its `tool` equals the file name without `.json`;
  3. `version` and `kind` are given together or not at all.

Remote checks (`--remote`, needs `gh` and `nix` and a token that can read the
pinned repository):
  4. `rev` exists in owner/repo;
  5. the fetched tree's narHash equals `narHash`;
  6. when `flake` is true, every `attrs` value is a package of the flake on
      each of the pin's `systems` (default x86_64-linux and aarch64-darwin);
  7. when `kind` is given, `rev` qualifies as that kind (the rule of
      metacraft-pm how-to-distribute-new-reprobuild-versions-internally.md,
      "Which revision may be pinned"): an ancestor of the repository's `dev`
      (`dev-commit`) or `agents` (`agents-commit`), or the commit of the
      annotated tag `v<version>` whose GitHub release is published and not a
      draft (`release`).

The remote checks read a token for each pinned owner from
GH_TOKEN_<OWNER> (the owner upper-cased, `-` as `_`), else GH_TOKEN. It is
handed to `gh` and to `nix` through their environment, never on a command line.

WHY A HAND-WRITTEN VALIDATOR. This runs on a stock runner with no pip step: a
guard must not share the failure modes of what it guards. It implements only
the keywords pin.schema.json uses (type, const, enum, pattern, minLength,
minItems, items, required, properties, additionalProperties as false or as a
schema), and refuses a
schema keyword it does not implement, so extending the schema cannot silently
weaken the check.

Usage: tools/check-pins.py [--remote] [--owner OWNER] [--list-owners] [--pins-dir DIR]
Exit status 0 when every file passes, 1 when any fails, 2 on a usage error.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

SYSTEMS = ("x86_64-linux", "aarch64-darwin")
# Keywords the validator understands; anything else in the schema is refused.
KNOWN = {
    "$schema", "$id", "title", "description", "default",
    "type", "const", "enum", "pattern", "minLength", "minItems", "items",
    "required", "properties", "additionalProperties",
}
TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool, "integer": int,
}


def validate(value, schema, where="$"):
    """Return a list of problems for `value` against `schema`."""
    unknown = set(schema) - KNOWN
    if unknown:
        return [f"{where}: schema uses unsupported keyword(s) {sorted(unknown)}"]
    problems = []
    if "const" in schema and (
        value != schema["const"] or type(value) is not type(schema["const"])
    ):
        problems.append(f"{where}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{where}: {value!r} is not one of {schema['enum']}")
    if "type" in schema:
        expected = TYPES[schema["type"]]
        ok = isinstance(value, expected)
        if expected is int and isinstance(value, bool):
            ok = False
        if expected is not bool and isinstance(value, bool):
            ok = False
        if not ok:
            return problems + [f"{where}: must be of type {schema['type']}"]
    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.append(f"{where}: {value!r} does not match {schema['pattern']}")
        if len(value) < schema.get("minLength", 0):
            problems.append(f"{where}: is shorter than {schema['minLength']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            problems.append(f"{where}: needs at least {schema['minItems']} item(s)")
        for index, item in enumerate(value):
            problems += validate(item, schema.get("items", {}), f"{where}[{index}]")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{where}: missing required field {key!r}")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if key in props:
                problems += validate(item, props[key], f"{where}.{key}")
            elif extra is False:
                problems.append(f"{where}: unknown field {key!r}")
            elif isinstance(extra, dict):
                problems += validate(item, extra, f"{where}.{key}")
    return problems


def check_local(path, schema):
    try:
        pin = json.loads(path.read_text())
    except (OSError, ValueError) as err:
        return None, [f"{path}: cannot be read as JSON: {err}"]
    problems = [f"{path}: {p}" for p in validate(pin, schema)]
    if isinstance(pin, dict) and pin.get("tool") != path.stem:
        problems.append(f"{path}: tool {pin.get('tool')!r} must equal the file name {path.stem!r}")
    if isinstance(pin, dict) and ("version" in pin) != ("kind" in pin):
        problems.append(f"{path}: version and kind must be given together")
    return pin, problems


def token_environment(owner):
    """The environment for gh and nix with the owner's token, if any."""
    env = dict(os.environ)
    token = env.get("GH_TOKEN_" + owner.upper().replace("-", "_")) or env.get("GH_TOKEN")
    if token:
        env["GH_TOKEN"] = token
        config = env.get("NIX_CONFIG", "")
        env["NIX_CONFIG"] = (config + "\n" if config else "") + f"access-tokens = github.com={token}"
    return env


def run(cmd, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def check_kind(path, pin, slug, env):
    """Problems with `rev` as the pinned `kind`; empty when it qualifies."""
    rev, kind = pin["rev"], pin["kind"]
    if kind in ("dev-commit", "agents-commit"):
        branch = kind.split("-", 1)[0]
        # compare/<branch>...<rev> is `behind` or `identical` exactly when rev
        # is an ancestor of the branch.
        got = run(["gh", "api", f"repos/{slug}/compare/{branch}...{rev}", "--jq", ".status"], env)
        status = got.stdout.strip()
        if got.returncode != 0 or status not in ("behind", "identical"):
            return [f"{path}: kind {kind} but rev {rev} is not an ancestor of {slug} {branch}"
                    f" (compare status {status or got.stderr.strip()[-200:]!r})"]
        return []
    tag = "v" + pin["version"]
    problems = []
    ref = run(["gh", "api", f"repos/{slug}/git/ref/tags/{tag}", "--jq", ".object.type"], env)
    if ref.returncode != 0 or ref.stdout.strip() != "tag":
        problems.append(f"{path}: kind release but {slug} has no annotated tag {tag}")
    commit = run(["gh", "api", f"repos/{slug}/commits/{tag}", "--jq", ".sha"], env)
    if commit.returncode != 0 or commit.stdout.strip() != rev:
        problems.append(f"{path}: kind release but tag {tag} is not rev {rev}"
                        f" ({commit.stdout.strip() or commit.stderr.strip()[-200:]})")
    release = run(["gh", "api", f"repos/{slug}/releases/tags/{tag}", "--jq", ".draft"], env)
    if release.returncode != 0 or release.stdout.strip() != "false":
        problems.append(f"{path}: kind release but {slug} has no published release {tag}")
    return problems


def check_remote(path, pin):
    """Network checks. Returns problems; never prints a token."""
    problems = []
    slug = f"{pin['owner']}/{pin['repo']}"
    env = token_environment(pin["owner"])
    got = run(["gh", "api", f"repos/{slug}/commits/{pin['rev']}", "--jq", ".sha"], env)
    if got.returncode != 0 or got.stdout.strip() != pin["rev"]:
        return [f"{path}: rev {pin['rev']} was not found in {slug}"]
    if "kind" in pin:
        problems += check_kind(path, pin, slug, env)
    ref = f"github:{slug}/{pin['rev']}"
    fetched = run(["nix", "flake", "prefetch", "--json", ref], env)
    if fetched.returncode != 0:
        return [f"{path}: {ref} is not fetchable: {fetched.stderr.strip()[-300:]}"]
    actual = json.loads(fetched.stdout).get("hash")
    if actual != pin["narHash"]:
        problems.append(f"{path}: narHash is {pin['narHash']} but the tree hashes to {actual}")
        return problems
    if pin.get("flake", True):
        locked = f"{ref}?narHash={pin['narHash']}"
        for system in pin.get("systems", SYSTEMS):
            res = run(["nix", "eval", "--json", f"{locked}#packages.{system}",
                        "--apply", "builtins.attrNames"], env)
            if res.returncode != 0:
                problems.append(f"{path}: cannot list packages.{system}: {res.stderr.strip()[-300:]}")
                continue
            have = set(json.loads(res.stdout))
            for role, attr in sorted(pin.get("attrs", {}).items()):
                if attr not in have:
                    problems.append(f"{path}: attrs.{role} = {attr!r} is not in packages.{system}")
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--remote", action="store_true")
    parser.add_argument("--owner", help="only the pins of this owner (with --remote)")
    parser.add_argument("--list-owners", action="store_true",
                        help="print the owners the pins name as a JSON list, and check nothing")
    parser.add_argument("--pins-dir", default=str(pathlib.Path(__file__).resolve().parent.parent / "pins"))
    args = parser.parse_args(argv)
    pins_dir = pathlib.Path(args.pins_dir)
    try:
        schema = json.loads((pins_dir / "pin.schema.json").read_text())
    except (OSError, ValueError) as err:
        print(f"error: cannot read the schema: {err}", file=sys.stderr)
        return 2
    files = sorted(p for p in pins_dir.glob("*.json") if p.name != "pin.schema.json")
    if not files:
        print(f"error: no pin files in {pins_dir}", file=sys.stderr)
        return 2
    if args.list_owners:
        owners = set()
        for path in files:
            pin, problems = check_local(path, schema)
            if problems:
                for problem in problems:
                    print(f"FAIL {problem}", file=sys.stderr)
                return 1
            owners.add(pin["owner"])
        print(json.dumps(sorted(owners)))
        return 0
    failed = False
    checked = 0
    for path in files:
        pin, problems = check_local(path, schema)
        if args.owner and isinstance(pin, dict) and pin.get("owner") != args.owner:
            continue
        checked += 1
        if not problems and args.remote:
            problems = check_remote(path, pin)
        for problem in problems:
            print(f"FAIL {problem}")
        failed = failed or bool(problems)
        if not problems:
            print(f"ok   {path.name}")
    if checked == 0:
        print(f"error: no pin names the owner {args.owner}", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
