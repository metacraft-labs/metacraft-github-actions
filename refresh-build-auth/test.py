"""No mocks: run the shipped refresh against real Git and Nix configuration.

Credentials are inert strings; no network request is made. Isolated config
files prevent the test from observing or changing the operator's credentials.
The old-token control proves Nix would otherwise keep using the expired value.
"""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import sys

root = Path(__file__).resolve().parent
for isolated_path in [False, True]:
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        empty = directory / "empty"
        empty.write_text("")
        environment_file = directory / "job-env"
        environment_file.write_text("")
        environment = dict(os.environ)
        environment.update(
            GITHUB_ENV=str(environment_file),
            GH_TOKEN="fresh-fixture-token",
            TOKEN_OWNERS="metacraft-labs",
            NIX_CONF_DIR=temporary,
            NIX_USER_CONF_FILES=str(empty),
            GIT_CONFIG_SYSTEM=str(empty),
            GIT_CONFIG_GLOBAL=str(empty),
            GIT_CONFIG_COUNT="0",
            NIX_CONFIG="http-connections = 7\naccess-tokens = github.com=old-fixture-token gitlab.com=preserved-fixture-token\n",
        )

        def nix_settings(env):
            return json.loads(subprocess.check_output(
                ["nix", "--extra-experimental-features", "nix-command", "show-config", "--json"],
                env=env, text=True, stderr=subprocess.DEVNULL,
            ))

        if isolated_path:
            tools = directory / "tools"
            tools.mkdir()
            for name in ["bash", "dirname", "base64", "tr", "git", "nix"]:
                executable = shutil.which(name)
                assert executable, name
                (tools / name).symlink_to(executable)
            environment["PATH"] = str(tools)
            environment["REPROBUILD_BOOTSTRAP_PYTHON"] = sys.executable
            assert shutil.which("python3", path=str(tools)) is None

        assert nix_settings(environment)["access-tokens"]["value"]["github.com"] == "old-fixture-token"
        subprocess.run(["bash", str(root / "refresh.sh")], env=environment,
                        check=True, capture_output=True, text=True)
        lines = iter(environment_file.read_text().splitlines())
        for line in lines:
            if "<<" in line:
                name, delimiter = line.split("<<", 1)
                value = []
                for part in lines:
                    if part == delimiter:
                        break
                    value.append(part)
                environment[name] = "\n".join(value)
            else:
                name, value = line.split("=", 1)
                environment[name] = value
        effective = nix_settings(environment)
        assert effective["access-tokens"]["value"] == {
            "github.com": "fresh-fixture-token",
            "gitlab.com": "preserved-fixture-token",
        }
        assert effective["http-connections"]["value"] == 7
        command = ["git", "config", "--get-urlmatch", "http.extraHeader"]
        header = subprocess.check_output(command + ["https://github.com/metacraft-labs/runquota"],
                                          env=environment, cwd=temporary, text=True).strip()
        expected = base64.b64encode(b"x-access-token:fresh-fixture-token").decode()
        assert header == "AUTHORIZATION: basic " + expected
        third_party = subprocess.run(command + ["https://github.com/NixOS/nixpkgs"],
                                      env=environment, cwd=temporary, capture_output=True)
        assert third_party.returncode == 1 and not third_party.stdout
        assert empty.read_text() == ""
print("Real Git and Nix use fresh credentials; other settings and scopes survive")
