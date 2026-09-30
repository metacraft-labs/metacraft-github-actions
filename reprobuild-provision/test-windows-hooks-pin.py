"""No mocks: run the Windows provisioner against real local Git repositories.

The CodeTracer fixture deliberately lacks its required submodules. Its later
refusal bounds this source-selection test before the unrelated BearSSL fetch.
The separate Windows bootstrap workflow validates complete native provisioning.
"""

import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPOS = (
    "runquota", "nim-stackable-hooks", "io-mon", "codetracer", "nim-shm-lease",
    "nim-shm-queue", "nim-shm-gset", "reprobuild-test-adapters",
    "reprobuild-ct-test-runner", "reprobuild-llm-agent-packages",
)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="windows-hook-pin-") as directory:
    root = Path(directory)
    config = root / "gitconfig"
    config.touch()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_CONFIG") and key != "GIT_AUTH_DIR"}
    env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", GH_TOKEN="",
               RUNNER_OS="Windows", RUNNER_TEMP=str(root), SIBLING_OWNER="fixture",
               RUNQUOTA_REF="dev", IO_MON_REF="dev", LC_ALL="C")
    run("git", "config", "--file", str(config), "protocol.file.allow", "always", env=env)
    run("git", "config", "--file", str(config),
        f"url.file://{root}/remotes/.insteadOf", "https://github.com/fixture/", env=env)
    source = root / "source"
    run("git", "init", "-b", "dev", str(source), env=env)

    def commit_version(version):
        (source / "version").write_text(version)
        run("git", "-C", str(source), "add", "version", env=env)
        run("git", "-C", str(source), "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", version.strip(), env=env)
        return run("git", "-C", str(source), "rev-parse", "HEAD", env=env).stdout.strip()

    pinned = commit_version("pinned source\n")
    original_dev = commit_version("original dev\n")
    (root / "remotes").mkdir()
    for name in REPOS:
        run("git", "clone", "--bare", str(source),
            str(root / "remotes" / f"{name}.git"), env=env)

    def provision(case, pin, expected):
        workspace = root / case / "workspace"
        workspace.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["bash", str(HERE / "provision-reprobuild-siblings.sh")], cwd=root,
            env=dict(env, GITHUB_WORKSPACE=str(workspace), STACKABLE_HOOKS_PIN=pin),
            text=True, capture_output=True)
        assert result.returncode != 0, "The intentionally absent submodules must fail"
        assert "source-only Nim submodules failed" in result.stdout, result.stdout + result.stderr
        hooks = workspace / "nim-stackable-hooks"
        actual = run("git", "-C", str(hooks), "rev-parse", "HEAD", env=env).stdout.strip()
        assert actual == expected, (pin, actual, expected)
        assert not (workspace / "nim-bearssl").exists()
        print(f"PASS Windows hook source {case}: {actual}")

    provision("default", "", original_dev)
    provision("pinned", pinned, pinned)
    advanced_dev = commit_version("advanced dev\n")
    run("git", "-C", str(source), "push",
        str(root / "remotes" / "nim-stackable-hooks.git"), "dev", env=env)
    provision("pinned", pinned, pinned)
    provision("advanced-default", "", advanced_dev)

    for index, invalid in enumerate(("dev", pinned[:7], "A" * 40, "../dev")):
        workspace = root / f"invalid-{index}"
        workspace.mkdir()
        result = subprocess.run(
            ["bash", str(HERE / "provision-reprobuild-siblings.sh")], cwd=root,
            env=dict(env, GITHUB_WORKSPACE=str(workspace), STACKABLE_HOOKS_PIN=invalid),
            text=True, capture_output=True)
        assert result.returncode == 2, result.stdout + result.stderr
        assert not list(workspace.iterdir()), "An invalid pin must not clone anything"
    print("PASS malformed hook pins are refused before cloning")
