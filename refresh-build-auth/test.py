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
import textwrap


def nix_settings(env):
    return json.loads(subprocess.check_output(
        [NIX, "--extra-experimental-features", "nix-command", "show-config", "--json"],
        env=env, text=True, stderr=subprocess.DEVNULL,
    ))


def apply_job_environment(path, environment):
    lines = iter(path.read_text().splitlines())
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


NIX = shutil.which("nix")
assert NIX, "the owning environment must provide Nix for real parser controls"

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
        apply_job_environment(environment_file, environment)
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

# Drive the actual known composite steps, using the same complete-file reader
# and named-step convention as the authenticated Cargo fixture. This is not an
# action-runner emulator: only these fixed input/output bindings are replayed.
# All credentials below are inert sentinels; the real Nix parser uses isolated
# configuration and never performs a network acquisition or reads host config.
repo = root.parent
node = os.environ.get("GHA_NIX_AUTH_NODE", "")
assert Path(node).is_absolute() and os.access(node, os.X_OK), "declared Node binding required"
reader = repo / ".github/read-workflow.cjs"
action = subprocess.check_output([node, str(reader), str(repo / "setup-dev-env/action.yml")], text=True)


def named_step(name, document=action):
    # The existing reader reads the complete YAML before this fixed named
    # step extraction; fixture execution remains limited to the owning steps.
    marker = "    - name: " + name + "\n"
    return document.split(marker, 1)[1].split("\n    - name:", 1)[0] if marker in document else None


def scalar_body(step, key):
    lines = step.split(key + ": |\n", 1)[1].splitlines()
    indentation = len(lines[0]) - len(lines[0].lstrip())
    body = []
    for line in lines:
        if line.strip() and len(line) - len(line.lstrip()) < indentation:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


# Execute both declared-runtime binding sites, not a source-string substitute.
# process.execPath must reach the next step through the real GITHUB_ENV format.
for binding_path in [repo / "refresh-build-auth/action.yml", repo / ".github/workflows/test.yml"]:
    document = subprocess.check_output([node, str(reader), str(binding_path)], text=True)
    binding = document.split("name: Bind declared Nix-auth Node runtime\n", 1)[1].split("- name:", 1)[0]
    assert "uses: actions/github-script@v7" in binding
    script = scalar_body(binding, "script")
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "environment"
        output.touch()
        subprocess.run([node, "-e", script], env=dict(os.environ, GITHUB_ENV=str(output)), check=True)
        bound = {}
        apply_job_environment(output, bound)
        assert Path(bound["GHA_NIX_AUTH_NODE"]).samefile(node)



def setup_control(token, *, github_credentials=True, flavor="reprobuild", nix_missing=False, caller="setup-dev-env", owners="metacraft-labs", invalid_config=False):
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        empty = directory / "empty"
        empty.touch()
        environment_file = directory / "job-env"
        environment_file.touch(mode=0o600)
        output = directory / "step-output"
        output.touch()
        home_config = directory / ".config/nix/nix.conf"
        home_config.parent.mkdir(parents=True)
        home_config.write_text("# readonly fixture; no helper may rewrite HOME config\n")
        home_config.chmod(0o444)
        initial = "http-connections = 7\naccess-tokens = gitlab.com=preserved-fixture-token"
        if github_credentials:
            initial += " github.com=old-fixture-token github.com/metacraft-labs=old-owner-fixture-token github.com/partner=partner-fixture-token"
        environment = dict(os.environ, HOME=temporary, NIX_CONF_DIR=temporary,
                            NIX_USER_CONF_FILES=str(empty), NIX_CONFIG=initial + "\n",
                            GIT_CONFIG_SYSTEM=str(empty), GIT_CONFIG_GLOBAL=str(empty),
                            GIT_CONFIG_COUNT="0", GITHUB_ENV=str(environment_file),
                            GITHUB_OUTPUT=str(output), GH_TOKEN=token, TOKEN_OWNERS=owners,
                            GITHUB_WORKSPACE=str(repo), GITHUB_ACTION_PATH=str(repo / caller),
                            MCL_CONSUMER_DIRECTORY=".", MCL_WORKSPACE_DIRECTORY=".",
                            GITHUB_SHA=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip())
        if invalid_config:
            environment["NIX_CONFIG"] += "http-connections = invalid-fixture-value\n"
        bash = shutil.which("bash")
        if nix_missing:
            tools = directory / "tools"
            tools.mkdir()
            for tool in ["bash", "dirname", "git"]:
                (tools / tool).symlink_to(shutil.which(tool))
            environment["PATH"] = str(tools)
        configured = None
        document = action if caller == "setup-dev-env" else subprocess.check_output(
            [node, str(reader), str(repo / caller / "action.yml")], text=True)
        step = named_step("Configure Nix authentication (reprobuild)" if caller == "setup-dev-env"
                          else "Select job-scoped Nix GitHub authentication", document)
        if step is not None and flavor == "reprobuild":
            if caller == "setup-dev-env":
                assert "if: ${{ inputs.env-flavor == 'reprobuild' }}" in step
            assert "uses: actions/github-script@v7" in step
            assert "GH_TOKEN: ${{ inputs.gh-token }}" in step
            assert "TOKEN_OWNERS: ${{ inputs.token-owner }}" in step
            binding = "roots" if caller == "setup-dev-env" else "nix_check"
            assert "GHA_NIX_AUTH_MODULE: ${{ steps." + binding + ".outputs.nix-auth-module }}" in step
            roots = named_step("Resolve explicit consumer and SDK roots" if caller == "setup-dev-env"
                                else "Detect pre-installed Nix", document)
            body = scalar_body(roots, "run")
            subprocess.run([bash, "-euo", "pipefail", "-c", body], env=environment, check=True, capture_output=True)
            outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
            environment["GHA_NIX_AUTH_MODULE"] = outputs["nix-auth-module"]
            script = scalar_body(step, "script")
            configured = subprocess.run([node, "-e", script], env=environment, capture_output=True, text=True)
        status = configured.returncode if configured else 0
        if flavor != "reprobuild" or nix_missing:
            assert status == 0 and environment_file.read_text() == ""
        elif invalid_config or (not token and github_credentials):
            assert status != 0, "invalid settings or empty credentials must fail closed"
            assert "old-fixture-token" not in configured.stdout + configured.stderr
            assert "invalid-fixture-value" not in configured.stdout + configured.stderr
            assert environment_file.read_text() == ""
        else:
            assert status == 0, "actual shared Nix auth step failed"
            apply_job_environment(environment_file, environment)
            effective = nix_settings(environment)
            if token:
                assert effective["access-tokens"]["value"] == {
                    "github.com": token, "github.com/metacraft-labs": token if owners else "old-owner-fixture-token",
                    "github.com/partner": "partner-fixture-token", "gitlab.com": "preserved-fixture-token",
                }, "actual setup step left the poisoned GitHub credential selected"
                public = "\n".join(line for line in configured.stdout.splitlines() if not line.startswith("::add-mask::"))
                for secret in [token, "old-fixture-token", "old-owner-fixture-token", "partner-fixture-token", "preserved-fixture-token"]:
                    assert secret not in public
                    assert "::add-mask::" + secret.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A") in configured.stdout
            else:
                assert effective["access-tokens"]["value"] == {"gitlab.com": "preserved-fixture-token"}
            assert effective["http-connections"]["value"] == 7
        assert home_config.read_text() == "# readonly fixture; no helper may rewrite HOME config\n"
        assert empty.read_text() == ""


setup_control("fresh-fixture-token")
setup_control("fresh-fixture-token", owners="")
setup_control("fresh-fixture-token", caller="setup-nix")
setup_control("fresh-fixture-token", invalid_config=True)
setup_control("fresh-fixture-token%mask-control")
setup_control("", github_credentials=False)
setup_control("")
setup_control("fresh-fixture-token", flavor="windows-diy")
setup_control("fresh-fixture-token", nix_missing=True)
print("Actual setup auth respects fresh/anonymous/refusal cases, scope, masks and HOME ownership")
