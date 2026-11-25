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

The step runs before any toolchain is installed. On the self-hosted macOS
runner mcl-bench-001 its PATH reaches bash, git and macOS's `/bin` (`rm`,
`ln`, `mkdir`, ...) but not `/usr/bin`: no python3, sed, awk, tr, sort,
grep or dirname. Cases 8-10 run the script and the lock reader with that
PATH, against reprobuild `b9cf09b07`'s real `flake.lock` (a
verbatim copy in `testdata/`) and against hand-written edge cases, and check
the reader against an independent Python reading of the same file.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "provision-reprobuild-siblings.sh"
READER = HERE / "flake-lock-revisions.sh"
# reprobuild v0.2.26's flake.lock, byte for byte (`git show b9cf09b07:flake.lock`).
B9_LOCK = HERE / "testdata" / "reprobuild-b9cf09b07.flake.lock"
B9_RUNQUOTA = "98ea3e58df67f736a8527788d1563e31291a4881"
REPOS = (
    "runquota", "nim-stackable-hooks", "io-mon", "codetracer", "nim-shm-lease",
    "nim-shm-queue", "nim-shm-gset", "reprobuild-test-adapters",
    "reprobuild-ct-test-runner", "reprobuild-llm-agent-packages",
    "test-certificates-tools", "codetracer-native-recorder",
    "nim-cli-spec", "nim-entrypoints", "nim-confutils",
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


def oracle(text):
    """An independent reading of a lock: the set of `<repo> <owner> <rev>`
    lines the reader must print, by the rules it documents."""
    lock = json.loads(text)
    nodes = lock["nodes"]
    found = set()
    for node_name in nodes[lock["root"]].get("inputs", {}).values():
        if not isinstance(node_name, str):
            continue
        locked = nodes.get(node_name, {}).get("locked", {})
        rev = locked.get("rev", "")
        if locked.get("type") in ("github", "gitlab", "sourcehut"):
            owner, repo = locked.get("owner", ""), locked.get("repo", "")
        elif locked.get("type") == "git":
            parts = locked.get("url", "").rstrip("/").split("/")
            owner = parts[-2] if len(parts) > 1 else ""
            repo = re.sub(r"\.git$", "", parts[-1])
        else:
            continue
        if owner and repo and re.fullmatch(r"[0-9a-f]{40}", rev):
            found.add(f"{repo.lower()} {owner.lower()} {rev}")
    return found


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
    assert f"runquota @ {locked} (locked by the reprobuild being built)" in out, out
    # Not an input of the reprobuild being built: not cloned at all. In the
    # default layout the workspace is the consumer's own checkout, and a stale
    # recorder copy there was scanned as part of the recorder under test.
    assert not (workspace / "codetracer-native-recorder").exists(), out
    assert "codetracer-native-recorder not cloned (the reprobuild being built has no such input)" in out, out
    print("PASS Linux source build clones the RunQuota its reprobuild locks")

    # 1b. A reprobuild that still takes the recorder as an input (its lock
    #     pins it: reprobuild before v0.2.0) gets it, at the locked revision.
    checkout = reprobuild_checkout("linux-old-recorder", dict(
        linux_pins, **{"codetracer-native-recorder": github("codetracer-native-recorder", locked)}))
    workspace, result = provision("linux-old-recorder", "Linux", checkout)
    out = result.stdout + result.stderr
    assert result.returncode == 0, out
    assert version(workspace, "codetracer-native-recorder") == "locked revision\n", out
    print("PASS a reprobuild whose lock pins the recorder still gets it")

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
    #    `git`-type input; an unpinned one keeps its mainline. The sibling-first
    #    packages reprobuild's config.nims reads from `../nim-cli-spec`,
    #    `../nim-entrypoints` and `../nim-confutils` are cloned when the lock
    #    pins them and skipped, not defaulted to a branch, when it does not
    #    (`nim-confutils` has no `dev`). Without them a v0.2.35 Windows source
    #    build cannot compile the engine, and its `repro exec` refuses with
    #    "no acceptable source for CLI_SPEC_SRC".
    checkout = reprobuild_checkout("windows", {
        "runquota-src": github("runquota", locked),
        "io-mon-src": github("io-mon", locked),
        "nim-stackable-hooks-src": github("nim-stackable-hooks", locked),
        "nim-shm-queue-src": github("nim-shm-queue", locked),
        "codetracer-src": github("codetracer", locked),
        "nim-cli-spec-src": github("nim-cli-spec", locked),
        "nim-confutils-src": github("nim-confutils", locked),
        "test-certificates-tools-src": {
            "type": "git", "url": "https://github.com/fixture/test-certificates-tools.git",
            "rev": locked}})
    workspace, result = provision("windows", "Windows", checkout)
    out = result.stdout + result.stderr
    assert result.returncode != 0, "the CodeTracer fixture lacks its submodules"
    assert "updating codetracer's source-only Nim submodules failed" in out, out
    for name in (
        "runquota", "io-mon", "nim-stackable-hooks", "nim-shm-queue",
        "codetracer", "test-certificates-tools", "nim-cli-spec", "nim-confutils",
    ):
        assert version(workspace, name) == "locked revision\n", name + "\n" + out
    assert not (workspace / "nim-entrypoints").exists(), out
    assert "nim-entrypoints not cloned (the reprobuild being built does not lock it)" in out, out
    for name in ("nim-shm-lease", "nim-shm-gset", "reprobuild-test-adapters"):
        assert version(workspace, name) == "dev tip\n", name + "\n" + out
    print("PASS Windows clones every sibling its reprobuild locks at that revision")

    # 7b. nim-shm-lease is RunQuota's dependency, and reprobuild's lock does
    #     not pin it: it follows the flake.lock of the RunQuota being cloned.
    #     reprobuild's Windows release staging (stage_release_runquota.sh)
    #     exports nim-shm-lease at exactly that revision from this clone; the
    #     `dev` clone lacked it, and pins.yml run 45588702864 stopped at
    #     "../nim-shm-lease does not have 08a3f50a...". Another owner's entry
    #     for the same repository loses to the clone owner's, as in the
    #     reprobuild lock.
    run("git", "-C", str(source), "checkout", "-q", "-b", "runquota-locks-lease", locked, env=env)
    (source / "flake.lock").write_text(flake_lock({
        "nim-shm-lease": github("nim-shm-lease", other),
        "nim-shm-lease-upstream": github("nim-shm-lease", base, owner="elsewhere"),
        "reprobuild": github("reprobuild", base)}))
    run("git", "-C", str(source), "add", "flake.lock", env=env)
    runquota_locking = commit("runquota locking nim-shm-lease\n")
    (source / "flake.lock").write_text(flake_lock({
        "lease-a": github("nim-shm-lease", other, owner="one"),
        "lease-b": github("nim-shm-lease", base, owner="two")}))
    run("git", "-C", str(source), "add", "flake.lock", env=env)
    runquota_conflicting = commit("runquota with two nim-shm-lease pins\n")
    (source / "flake.lock").write_text("{\"nodes\": {")
    run("git", "-C", str(source), "add", "flake.lock", env=env)
    runquota_malformed = commit("runquota with a malformed lock\n")
    run("git", "-C", str(source), "checkout", "-q", "dev", env=env)
    run("git", "-C", str(source), "push", "-q", str(root / "remotes" / "runquota.git"),
        "runquota-locks-lease", env=env)
    windows_pins = {
        "runquota-src": github("runquota", runquota_locking),
        "io-mon-src": github("io-mon", locked),
        "nim-stackable-hooks-src": github("nim-stackable-hooks", locked),
        "test-certificates-tools-src": github("test-certificates-tools", locked)}
    checkout = reprobuild_checkout("windows-lease", windows_pins)
    workspace, result = provision("windows-lease", "Windows", checkout)
    out = result.stdout + result.stderr
    assert "updating codetracer's source-only Nim submodules failed" in out, out
    assert version(workspace, "runquota") == "runquota locking nim-shm-lease\n", out
    assert version(workspace, "nim-shm-lease") == "another revision\n", (
        "nim-shm-lease was not cloned at the revision the runquota clone locks:\n" + out)
    assert f"nim-shm-lease @ {other} (locked by the runquota being cloned)" in out, out
    print("PASS Windows clones nim-shm-lease at the revision the runquota clone locks")

    # 7c. A reprobuild lock that does pin nim-shm-lease still wins.
    checkout = reprobuild_checkout("windows-lease-reprobuild", dict(
        windows_pins, **{"nim-shm-lease-src": github("nim-shm-lease", locked)}))
    workspace, result = provision("windows-lease-reprobuild", "Windows", checkout)
    out = result.stdout + result.stderr
    assert version(workspace, "nim-shm-lease") == "locked revision\n", out
    assert f"nim-shm-lease @ {locked} (locked by the reprobuild being built)" in out, out
    print("PASS a reprobuild lock that pins nim-shm-lease overrides the runquota lock")

    # 7d. A runquota lock with no single answer, or one that cannot be read,
    #     refuses before nim-shm-lease is cloned.
    for case, rev, message in (
        ("windows-lease-conflict", runquota_conflicting,
          "pins nim-shm-lease at more than one revision"),
        ("windows-lease-malformed", runquota_malformed,
          "could not read the nim-shm-lease revision from"),
    ):
        checkout = reprobuild_checkout(case, dict(
            windows_pins, **{"runquota-src": github("runquota", rev)}))
        workspace, result = provision(case, "Windows", checkout)
        out = result.stdout + result.stderr
        assert result.returncode != 0, out
        assert message in out, out
        assert not (workspace / "nim-shm-lease").exists(), out
    print("PASS a conflicting or unreadable runquota lock is refused before nim-shm-lease is cloned")

    # The PATH of the provisioning step on mcl-bench-001: bash, git and the
    # tools macOS keeps in /bin. Nothing from /usr/bin.
    bash, git = shutil.which("bash"), shutil.which("git")
    assert bash and git, "the suite needs bash and git"
    bare_path = root / "macos-bin"
    bare_path.mkdir()
    for tool in ("bash", "git", "rm", "ln", "mkdir", "cat"):
        found = shutil.which(tool)
        assert found, f"the suite needs {tool}"
        (bare_path / tool).symlink_to(found)
    bare_env = dict(env, PATH=str(bare_path))

    def provision_bare(case, checkout):
        workspace = root / case / "workspace"
        workspace.mkdir(parents=True)
        # GITHUB_ACTION_PATH and GIT_AUTH_DIR as the action's step sets them.
        case_env = dict(bare_env, RUNNER_OS="macOS", GITHUB_WORKSPACE=str(workspace),
                        REPROBUILD_SOURCE_DIRECTORY=str(checkout),
                        GITHUB_ACTION_PATH=str(HERE), GIT_AUTH_DIR=str(HERE.parent / "git-auth"))
        result = subprocess.run([bash, "--noprofile", "--norc", str(SCRIPT)], cwd=root,
                                text=True, capture_output=True, env=case_env, timeout=120)
        return workspace, result, result.stdout + result.stderr

    # 8. The defect: reprobuild b9cf09b07's own lock, read with that PATH. The reader must find RunQuota's locked revision; the
    #    fixture remotes do not hold that commit, so the run then stops at the
    #    clone, after the resolution this case is about.
    checkout = root / "b9-lock" / "reprobuild-src"
    checkout.mkdir(parents=True)
    shutil.copyfile(B9_LOCK, checkout / "flake.lock")
    workspace, result, out = provision_bare("b9-lock", checkout)
    assert "needs a working python3" not in out, out
    assert "command not found" not in out, out
    assert f"runquota @ {B9_RUNQUOTA} (locked by the reprobuild being built)" in out, (
        "the RunQuota revision reprobuild b9cf09b07 locks was not read:\n" + out)
    for name, rev in (("io-mon", "30d85793e891c1a80859d52a9eb197b42d56752c"),
                      ("nim-stackable-hooks", "d715806424e8373708494913e59a48237978cc2a"),
                      ("test-certificates-tools", "a726655886808d1062390d05c50f4fce03150eb4")):
        assert f"{name} @ {rev} (locked by the reprobuild being built)" in out, name + "\n" + out
    # b9cf09b07 (v0.2.26) has no recorder input.
    assert "codetracer-native-recorder not cloned (the reprobuild being built has no such input)" in out, out
    print(f"PASS without python3 or /usr/bin on PATH, b9cf09b07's lock yields runquota @ {B9_RUNQUOTA[:12]}")

    # 9. The whole Linux/macOS path with that PATH: every clone lands
    #    at the locked revision.
    checkout = reprobuild_checkout("bare-locked", linux_pins)
    workspace, result, out = provision_bare("bare-locked", checkout)
    assert result.returncode == 0, out
    assert "command not found" not in out, out
    assert version(workspace, "runquota") == "locked revision\n", out
    assert not (workspace / "codetracer-native-recorder").exists(), out
    print("PASS without python3 or /usr/bin on PATH, the source build provisions the locked RunQuota")

    # 9b. The refusals hold with that PATH: a missing lock, and one
    #     cloned sibling pinned at two revisions.
    checkout = reprobuild_checkout("bare-no-lock", None)
    workspace, result, out = provision_bare("bare-no-lock", checkout)
    assert result.returncode != 0 and "has no flake.lock" in out, out
    assert not list(workspace.iterdir())
    checkout = reprobuild_checkout("bare-conflict", {
        "runquota-a": github("runquota", locked, owner="one"),
        "runquota-b": github("runquota", other, owner="two")})
    workspace, result, out = provision_bare("bare-conflict", checkout)
    assert result.returncode != 0, out
    assert f"pins runquota at more than one revision ({locked} {other})" in out \
        or f"pins runquota at more than one revision ({other} {locked})" in out, out
    assert not list(workspace.iterdir())
    print("PASS without python3 or /usr/bin on PATH, a missing or conflicting lock is refused")

    # 10. The reader itself, against the independent reading above, on the
    #     real lock and on layouts Nix does not write but JSON allows.
    def read_lock(text, name):
        lock_file = root / "reader" / name
        lock_file.parent.mkdir(exist_ok=True)
        lock_file.write_bytes(text.encode("utf-8"))
        command = f'. "{READER}" && flake_lock_revisions "{lock_file}"'
        result = subprocess.run([bash, "--noprofile", "--norc", "-c", command],
                                text=True, capture_output=True, env=bare_env, timeout=60)
        return result

    sha = "0123456789abcdef0123456789abcdef01234567"
    tricky = {
        "nodes": {
            "root": {"inputs": {
                "a": "node \"quoted\" \\", "b": ["a"], "c": "git-node",
                "d": "upper", "e": "path-node", "f": "short-rev", "g": "dup"}},
            "node \"quoted\" \\": {"locked": {
                "type": "github", "owner": "o", "repo": "r", "rev": sha,
                "narHash": "sha256-\"}{[],:\\", "lastModified": 1.5e3, "flag": True,
                "none": None, "list": [1, "x", {"k": [False]}]}},
            "git-node": {"locked": {"type": "git", "rev": sha,
                                    "url": "https://example.invalid/Some/Thing.git/"}},
            "upper": {"locked": {"type": "gitlab", "owner": "MetaCraft", "repo": "IO-Mon", "rev": sha}},
            "path-node": {"locked": {"type": "path", "path": "/x", "rev": sha}},
            "short-rev": {"locked": {"type": "github", "owner": "o", "repo": "s", "rev": "abc"}},
            "dup": {"locked": {"type": "github", "owner": "o", "repo": "r", "rev": sha}},
            "unreferenced": {"locked": {"type": "github", "owner": "o", "repo": "u", "rev": sha}},
        },
        "root": "root",
        "version": 7,
    }
    cases = {
        "b9cf09b07.lock": B9_LOCK.read_text(),
        "pretty.lock": json.dumps(tricky, indent=2),
        "minified.lock": json.dumps(tricky, separators=(",", ":")),
        "crlf.lock": json.dumps(tricky, indent=1).replace("\n", "\r\n"),
        "root-first.lock": json.dumps({"root": "root", "nodes": tricky["nodes"]}),
    }
    for name, text in cases.items():
        result = read_lock(text, name)
        assert result.returncode == 0, f"{name}: {result.stderr}"
        got = result.stdout.splitlines()
        assert len(got) == len(set(got)), f"{name}: duplicate lines {got}"
        assert set(got) == oracle(text), f"{name}: {sorted(got)} != {sorted(oracle(text))}"
    assert f"runquota metacraft-labs {B9_RUNQUOTA}" in read_lock(cases["b9cf09b07.lock"], "again").stdout
    assert set(read_lock(cases["pretty.lock"], "p2").stdout.splitlines()) == {
        f"r o {sha}", f"thing some {sha}", f"io-mon metacraft {sha}"}
    print("PASS the lock reader agrees with an independent JSON reading on every layout")

    malformed = {
        "truncated.lock": B9_LOCK.read_text()[:5000],
        "unterminated-string.lock": '{"root": "ro',
        "no-root.lock": '{"nodes": {}}',
        "stray.lock": '{"root": "root", "nodes": {} } x',
        "missing-colon.lock": '{"root" "root"}',
        "empty.lock": "",
    }
    for name, text in malformed.items():
        result = read_lock(text, name)
        assert result.returncode != 0, f"{name}: accepted: {result.stdout}"
        assert result.stdout == "", f"{name}: printed {result.stdout!r}"
        assert "unreadable flake.lock" in result.stderr, f"{name}: {result.stderr}"
    print("PASS a malformed lock is refused, not read as pinning nothing")
