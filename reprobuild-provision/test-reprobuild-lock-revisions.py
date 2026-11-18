"""No mocks: a source build provisions the siblings the pinned reprobuild locks.

Property protected: when `reprobuild-source-directory` names the reprobuild
checkout being built, each sibling is cloned at the revision that checkout's
`flake.lock` records for it -- not at a named mainline -- unless the caller
names a revision explicitly. A named checkout without a usable lock is a
refusal before anything is cloned.

Regression test for a source build of reprobuild v0.2.26: it locks
`runquota-src` at a RunQuota `agents` commit, the provisioner cloned
`runquota@dev`, and the build failed at
`cannot open file: runquota_client/pressure_text`.

Real local Git repositories stand in for the remotes through URL rewrites,
and the real provisioning script runs against them. The CodeTracer fixture
lacks its submodules, so a Windows run ends at the (unrelated) selective
submodule update, after every clone asserted on here.
"""

import json
import os
from pathlib import Path
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


def flake_lock(pins):
    """A flake.lock in Nix's shape: root inputs naming locked nodes."""
    nodes = {"root": {"inputs": {}}}
    for input_name, locked in pins.items():
        nodes["root"]["inputs"][input_name] = input_name
        nodes[input_name] = {"locked": locked, "original": {}}
    nodes["root"]["inputs"]["nixpkgs"] = "nixpkgs"
    nodes["nixpkgs"] = {"locked": {"type": "github", "owner": "NixOS",
                                    "repo": "nixpkgs", "rev": "0" * 40}}
    nodes["root"]["inputs"]["follower"] = ["nixpkgs"]
    return json.dumps({"nodes": nodes, "root": "root", "version": 7}, indent=2)


def github(repo, rev, owner="fixture"):
    return {"type": "github", "owner": owner, "repo": repo, "rev": rev}


with tempfile.TemporaryDirectory(prefix="reprobuild-lock-revs-") as directory:
    root = Path(directory)
    config = root / "gitconfig"
    config.touch()
    scrubbed = (
        "GIT_AUTH_DIR", "RUNQUOTA_REF", "IO_MON_REF", "STACKABLE_HOOKS_PIN",
        "TEST_CERTIFICATES_TOOLS_REF", "REPROBUILD_SOURCE_DIRECTORY",
    )
    env = {
        k: v for k, v in os.environ.items()
        if not k.startswith("GIT_CONFIG") and k not in scrubbed
    }
    env.update(
        GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", GH_TOKEN="",
        RUNNER_TEMP=str(root), SIBLING_OWNER="fixture", LC_ALL="C",
    )
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

    base = commit("base revision\n")
    other = commit("another revision\n")
    commit("dev tip\n")
    run("git", "-C", str(source), "branch", "stable", env=env)
    # The locked revision is reachable only from `agents`, never from `dev`:
    # the shape of the real defect (RunQuota work not yet promoted to `dev`).
    run("git", "-C", str(source), "checkout", "-q", "-b", "agents", base, env=env)
    locked = commit("locked revision\n")
    run("git", "-C", str(source), "checkout", "-q", "dev", env=env)
    (root / "remotes").mkdir()
    for name in REPOS:
        run("git", "clone", "--bare", str(source),
            str(root / "remotes" / f"{name}.git"), env=env)

    def reprobuild_checkout(case, pins):
        checkout = root / case / "reprobuild-src"
        checkout.mkdir(parents=True)
        if pins is not None:
            (checkout / "flake.lock").write_text(flake_lock(pins))
        return checkout

    def provision(case, os_name, checkout, **extra):
        workspace = root / case / "workspace"
        workspace.mkdir(parents=True)
        case_env = dict(env, RUNNER_OS=os_name, GITHUB_WORKSPACE=str(workspace), **extra)
        if checkout is not None:
            case_env["REPROBUILD_SOURCE_DIRECTORY"] = str(checkout)
        result = subprocess.run(["bash", str(SCRIPT)], cwd=root, text=True,
                                capture_output=True, env=case_env)
        return workspace, result

    def version(workspace, name):
        return (workspace / name / "version").read_text()

    linux_pins = {"runquota-src": github("runquota", locked)}

    # 1. The defect: no RunQuota input, a reprobuild whose lock pins RunQuota
    #    away from `dev`. The clone must be the locked revision.
    checkout = reprobuild_checkout("linux-locked", linux_pins)
    workspace, result = provision("linux-locked", "Linux", checkout)
    out = result.stdout + result.stderr
    assert result.returncode == 0, out
    assert version(workspace, "runquota") == "locked revision\n", (
        "runquota was not cloned at the revision the reprobuild being built locks:\n" + out)
    # Not pinned by the lock: the named mainline remains.
    assert version(workspace, "codetracer-native-recorder") == "dev tip\n", out
    assert f"runquota @ {locked} (locked by the reprobuild being built)" in out, out
    print("PASS Linux source build clones the RunQuota its reprobuild locks")

    # 2. An explicit caller input still wins over the lock.
    checkout = reprobuild_checkout("linux-explicit", linux_pins)
    workspace, result = provision("linux-explicit", "Linux", checkout, RUNQUOTA_REF=other)
    assert result.returncode == 0, result.stdout + result.stderr
    assert version(workspace, "runquota") == "another revision\n"
    print("PASS an explicit runquota-ref overrides the lock")

    # 3. No reprobuild checkout named: the standalone defaults are unchanged.
    workspace, result = provision("linux-standalone", "Linux", None)
    assert result.returncode == 0, result.stdout + result.stderr
    assert version(workspace, "runquota") == "dev tip\n"
    print("PASS a standalone call keeps the named-mainline default")

    # 4. A named checkout without a lock is a refusal before any clone.
    checkout = reprobuild_checkout("linux-no-lock", None)
    workspace, result = provision("linux-no-lock", "Linux", checkout)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "has no flake.lock" in result.stdout + result.stderr
    assert not list(workspace.iterdir()), "a missing lock must refuse before cloning"
    print("PASS a named reprobuild checkout without flake.lock is refused")

    # 5. Inputs are matched by repository coordinates: the clone owner's own
    #    entry wins over a same-named repository of another owner.
    checkout = reprobuild_checkout("linux-owner", {
        "runquota-src": github("runquota", locked),
        "runquota-upstream": github("runquota", other, owner="elsewhere")})
    workspace, result = provision("linux-owner", "Linux", checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert version(workspace, "runquota") == "locked revision\n"
    print("PASS the clone owner's lock entry is preferred by coordinates")

    # 6. Two other owners' entries disagreeing on a CLONED sibling is a
    #    refusal before any clone; disagreement on a repository this action
    #    never clones is not.
    checkout = reprobuild_checkout("linux-conflict", {
        "runquota-a": github("runquota", locked, owner="one"),
        "runquota-b": github("runquota", other, owner="two")})
    workspace, result = provision("linux-conflict", "Linux", checkout)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "pins runquota at more than one revision" in result.stdout + result.stderr
    assert not list(workspace.iterdir())
    checkout = reprobuild_checkout("linux-unrelated-conflict", {
        "runquota-src": github("runquota", locked),
        "nim-stew-a": github("nim-stew", locked, owner="one"),
        "nim-stew-b": github("nim-stew", other, owner="two")})
    workspace, result = provision("linux-unrelated-conflict", "Linux", checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    print("PASS only a conflict on a cloned sibling is refused")

    # 7. Windows: every env.ps1 sibling the lock pins follows it, including a
    #    `git`-type input; an unpinned one keeps its mainline.
    checkout = reprobuild_checkout("windows", {
        "runquota-src": github("runquota", locked),
        "io-mon-src": github("io-mon", locked),
        "nim-stackable-hooks-src": github("nim-stackable-hooks", locked),
        "nim-shm-queue-src": github("nim-shm-queue", locked),
        "codetracer-src": github("codetracer", locked),
        "test-certificates-tools-src": {
            "type": "git", "url": "https://github.com/fixture/test-certificates-tools.git",
            "rev": locked}})
    workspace, result = provision("windows", "Windows", checkout)
    out = result.stdout + result.stderr
    assert result.returncode != 0, "the CodeTracer fixture lacks its submodules"
    assert "updating codetracer's source-only Nim submodules failed" in out, out
    for name in (
        "runquota", "io-mon", "nim-stackable-hooks", "nim-shm-queue",
        "codetracer", "test-certificates-tools",
    ):
        assert version(workspace, name) == "locked revision\n", name + "\n" + out
    for name in ("nim-shm-lease", "nim-shm-gset", "reprobuild-test-adapters"):
        assert version(workspace, name) == "dev tip\n", name + "\n" + out
    print("PASS Windows clones every sibling its reprobuild locks at that revision")
