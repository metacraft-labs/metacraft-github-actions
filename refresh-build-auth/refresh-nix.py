"""Refresh Nix's effective GitHub credential in the job environment only."""

import json
import os
import subprocess
import uuid

settings = subprocess.run(
    ["nix", "--extra-experimental-features", "nix-command", "show-config", "--json"],
    check=True,
    capture_output=True,
    text=True,
)
tokens = json.loads(settings.stdout)["access-tokens"]["value"]
# Register every credential carried into job environment metadata before export.
# Escaping follows the runner workflow-command data protocol; no config change.
for value in set(tokens.values()) | {os.environ["GH_TOKEN"]}:
    if value:
        escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print("::add-mask::" + escaped, flush=True)
tokens["github.com"] = os.environ["GH_TOKEN"]
for owner in os.environ.get("TOKEN_OWNERS", "metacraft-labs").split():
    prefix = "github.com/" + owner
    if prefix in tokens:
        tokens[prefix] = os.environ["GH_TOKEN"]
config = os.environ.get("NIX_CONFIG", "").rstrip("\n")
config += "\naccess-tokens = " + " ".join(
    host + "=" + value for host, value in sorted(tokens.items())
) + "\n"
delimiter = "nix_auth_" + uuid.uuid4().hex
with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
    output.write("NIX_CONFIG<<" + delimiter + "\n" + config + delimiter + "\n")
print("Refreshed job-scoped Nix GitHub authentication")
