"""No mocks: provision from real local Git repos through URL rewrites."""

import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="repro-bootstrap-ref-") as directory:
    root = Path(directory)
    config = root / "gitconfig"
    config.touch()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_CONFIG")}
    env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", GH_TOKEN="",
               RUNNER_OS="Linux", RUNNER_TEMP=str(root), SIBLING_OWNER="fixture")
    run("git", "config", "--file", str(config), "protocol.file.allow", "always", env=env)
    run("git", "config", "--file", str(config),
        f"url.file://{root}/remotes/.insteadOf", "https://github.com/fixture/", env=env)
    source = root / "source"
    run("git", "init", "-b", "dev", str(source), env=env)
    (source / "version").write_text("pinned\n")
    run("git", "-C", str(source), "add", "version", env=env)
    commit = ["git", "-C", str(source), "-c", "user.name=Fixture",
              "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
              "commit", "-m"]
    run(*commit, "pinned input", env=env)
    pinned = run("git", "-C", str(source), "rev-parse", "HEAD", env=env).stdout.strip()
    (source / "version").write_text("dev\n")
    run("git", "-C", str(source), "add", "version", env=env)
    run(*commit, "new mainline input", env=env)
    run("git", "-C", str(source), "branch", "stable", env=env)
    (root / "remotes").mkdir()
    for name in ("runquota", "codetracer-native-recorder"):
        run("git", "clone", "--bare", str(source), str(root / "remotes" / f"{name}.git"), env=env)
    for index, (ref, expected) in enumerate((("", "dev\n"), (pinned, "pinned\n"),
                                            ("absent-ref", None))):
        workspace = root / f"case-{index}" / "workspace"
        workspace.mkdir(parents=True)
        case_env = dict(env, GITHUB_WORKSPACE=str(workspace), RUNQUOTA_REF=ref)
        result = subprocess.run(["bash", str(HERE / "provision-reprobuild-siblings.sh")],
                                cwd=root, env=case_env, text=True, capture_output=True)
        if expected is None:
            assert result.returncode != 0, result.stdout
            assert not (workspace / "runquota").exists()
            assert not (workspace / "codetracer-native-recorder").exists()
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            assert (workspace / "runquota" / "version").read_text() == expected
            assert (workspace / "codetracer-native-recorder" / "version").read_text() == "dev\n"
        print(f"PASS bootstrap RunQuota ref {ref or '(default dev)'}")
