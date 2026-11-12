"""No mocks: the Windows provisioner clones test-certificates-tools, at a revision.

Reprobuild's engine links the `test_certificates` Nim package from the sibling
`../test-certificates-tools/src` (config.nims). A Windows source build without
that sibling dies at `certificate_store.nim: cannot open file:
test_certificates/roots` and yields no `repro`, so the Windows path must clone
it. It is cloned at a pinned revision (the one Reprobuild's flake pins, which
is on the repo's `agents` branch and ahead of `dev`), so this test also
proves the revision, not the branch tip, is what lands.

Real local Git repositories stand in for the remotes through URL rewrites. The
CodeTracer fixture deliberately lacks its submodules, so the run ends at the
(unrelated) selective submodule update, which is after every clone asserted on.
"""

import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "provision-reprobuild-siblings.sh"
REPOS = (
    "runquota", "nim-stackable-hooks", "io-mon", "codetracer", "nim-shm-lease",
    "nim-shm-queue", "nim-shm-gset", "reprobuild-test-adapters",
    "reprobuild-ct-test-runner", "reprobuild-llm-agent-packages",
    "test-certificates-tools", "codetracer-native-recorder",
)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="test-certificates-tools-") as directory:
    root = Path(directory)
    config = root / "gitconfig"
    config.touch()
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("GIT_CONFIG") and k != "GIT_AUTH_DIR"}
    env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", GH_TOKEN="",
               RUNNER_TEMP=str(root), SIBLING_OWNER="fixture", RUNQUOTA_REF="dev",
               IO_MON_REF="dev", LC_ALL="C")
    run("git", "config", "--file", str(config), "protocol.file.allow", "always", env=env)
    run("git", "config", "--file", str(config),
        f"url.file://{root}/remotes/.insteadOf", "https://github.com/fixture/", env=env)
    source = root / "source"
    run("git", "init", "-b", "dev", str(source), env=env)

    def commit(text):
        (source / "version").write_text(text)
        run("git", "-C", str(source), "add", "version", env=env)
        run("git", "-C", str(source), "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", text.strip(), env=env)
        return run("git", "-C", str(source), "rev-parse", "HEAD", env=env).stdout.strip()

    pinned = commit("pinned revision\n")
    commit("dev tip\n")
    run("git", "-C", str(source), "branch", "stable", env=env)
    (root / "remotes").mkdir()
    for name in REPOS:
        run("git", "clone", "--bare", str(source),
            str(root / "remotes" / f"{name}.git"), env=env)

    def provision(case, os_name, ref):
        workspace = root / case / "workspace"
        workspace.mkdir(parents=True)
        result = subprocess.run(
            ["bash", str(SCRIPT)], cwd=root, text=True, capture_output=True,
            env=dict(env, RUNNER_OS=os_name, GITHUB_WORKSPACE=str(workspace),
                     TEST_CERTIFICATES_TOOLS_REF=ref))
        return workspace, result

    # Windows: cloned, at the pinned revision rather than the dev tip.
    workspace, result = provision("windows", "Windows", pinned)
    assert result.returncode != 0, "the CodeTracer fixture lacks its submodules"
    clone = workspace / "test-certificates-tools"
    assert clone.is_dir(), result.stdout + result.stderr
    assert (clone / "version").read_text() == "pinned revision\n"
    print("PASS Windows clones test-certificates-tools at the pinned revision")

    # Windows: listed in check_pins, so a wrong ref is refused before ANY clone.
    workspace, result = provision("windows-bad-ref", "Windows", "absent-branch")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "test-certificates-tools has no branch 'absent-branch'" in (
        result.stdout + result.stderr), result.stdout + result.stderr
    assert not list(workspace.iterdir()), "a bad pin must refuse before cloning"
    print("PASS Windows preflights the test-certificates-tools pin")

    # Linux gets the package from the flake input, so it is not cloned there.
    workspace, result = provision("linux", "Linux", pinned)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (workspace / "test-certificates-tools").exists()
    print("PASS Linux/macOS path does not clone test-certificates-tools")

# The built-in default must be a full SHA: a branch name would silently track
# the wrong source (see the comment above TEST_CERTIFICATES_TOOLS_REF).
default = re.search(r'TEST_CERTIFICATES_TOOLS_REF:-([^}]*)\}', SCRIPT.read_text())
assert default and re.fullmatch(r"[0-9a-f]{40}", default.group(1)), default
print("PASS the default revision is a full SHA")
