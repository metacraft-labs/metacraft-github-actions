"""No mocks: a multi-owner `SIBLING_OWNER` clones from its first word.

`setup-dev-env` passes its `token-owner` input to this provisioner as
`sibling-owner`, and that input is a whitespace-separated LIST
(`metacraft-labs aiken-lang` in codetracer-cardano-recorder). The provisioner
used the list verbatim as one owner, so every preflight asked about
`metacraft-labs aiken-lang/<repo>` and the source build failed before cloning
anything. This suite runs the real provisioner (Linux path) against real local
bare repositories reached through `url.<file-url>.insteadOf`, the same way
`test-runquota-ref.py` does, and checks:

  * `SIBLING_OWNER="fixture otherowner"` clones every sibling from `fixture`,
    the FIRST word, and succeeds. Only `https://github.com/fixture/` is
    rewritten to the local remotes, so a clone from `otherowner`, or from the
    whole list taken as one owner, cannot succeed.
  * the credential is still scoped to EVERY listed owner (read from the
    provisioner's `scoped-git-auth` report, which prints each scope), because
    that is the same list `setup-nix` scopes the job's credential to.
  * a whitespace-only `SIBLING_OWNER` falls back to `metacraft-labs`, never to
    an empty owner. `https://github.com/metacraft-labs/` is rewritten to a
    second set of remotes whose content differs, so the assertion shows which
    owner was used.

The token is a constant that authenticates nothing: the remotes are `file://`
URLs, so no header is ever sent, and nothing here prints it.
"""

import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "provision-reprobuild-siblings.sh"
TOKEN = "ghs_TESTONLYnotarealtoken0000000000000000"
SIBLINGS = ("runquota", "codetracer-native-recorder")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


def make_remotes(root, env, owner_dir, content):
    """Bare `runquota` and `codetracer-native-recorder` with `dev` and `stable`."""
    source = root / f"source-{owner_dir}"
    run("git", "init", "-b", "dev", str(source), env=env)
    (source / "owner").write_text(content)
    run("git", "-C", str(source), "add", "owner", env=env)
    run("git", "-C", str(source), "-c", "user.name=Fixture",
        "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-m", "fixture", env=env)
    run("git", "-C", str(source), "branch", "stable", env=env)
    remotes = root / owner_dir
    remotes.mkdir()
    for name in SIBLINGS:
        run("git", "clone", "--bare", str(source), str(remotes / f"{name}.git"), env=env)
    return remotes


with tempfile.TemporaryDirectory(prefix="repro-multi-owner-") as directory:
    root = Path(directory)
    config = root / "gitconfig"
    config.touch()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_CONFIG")}
    env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1",
                RUNNER_OS="Linux", RUNNER_TEMP=str(root))
    run("git", "config", "--file", str(config), "protocol.file.allow", "always", env=env)
    for owner, content in (("fixture", "fixture\n"), ("metacraft-labs", "default\n")):
        remotes = make_remotes(root, env, owner, content)
        run("git", "config", "--file", str(config),
            f"url.file://{remotes}/.insteadOf", f"https://github.com/{owner}/", env=env)

    cases = (
        # (SIBLING_OWNER, GH_TOKEN, expected owner file, expected scopes)
        ("fixture otherowner", TOKEN, "fixture\n",
          ("https://github.com/fixture/", "https://github.com/otherowner/")),
        ("  \t ", "", "default\n", ()),
    )
    for index, (owners, token, expected, scopes) in enumerate(cases):
        workspace = root / f"case-{index}" / "workspace"
        workspace.mkdir(parents=True)
        case_env = dict(env, GITHUB_WORKSPACE=str(workspace), SIBLING_OWNER=owners,
                        GH_TOKEN=token)
        result = subprocess.run(["bash", str(SCRIPT)], cwd=root, env=case_env,
                                text=True, capture_output=True)
        output = result.stdout + result.stderr
        assert TOKEN not in output, "the token was printed"
        assert result.returncode == 0, output
        for name in SIBLINGS:
            assert (workspace / name / "owner").read_text() == expected, (name, output)
        first = owners.split()[0] if owners.split() else "metacraft-labs"
        for name in SIBLINGS:
            assert f"reprobuild-provision: {first}/{name} @" in output, (name, output)
        assert "otherowner/" not in output.replace("https://github.com/otherowner/", ""), output
        for scope in scopes:
            assert f"  {scope}\n" in result.stdout, (scope, output)
        print(f"PASS multi-owner sibling-owner {owners!r} clones from {first!r}")
