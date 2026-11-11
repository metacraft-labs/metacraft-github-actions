"""No mocks: the failure message for codetracer's selective submodule update.

The provisioner used to answer EVERY failure of that update with one sentence
blaming the credential's owner scope and discarded git's stderr, so a transient
network fault was reported as a configuration mistake and the real error could
not be recovered from the log. This suite runs the real provisioner (Windows
path) against real local git repositories and the real authenticating HTTP git
server in `git-auth/`, and asserts, per scenario, what the log says:

  * auth      a submodule under ANOTHER owner whose server demands a credential
              the scoped token does not cover: the owner-scope explanation is
              kept, and the failing URL is named.
  * network   a submodule URL whose host refuses connections: git's real
              error is shown, the owner-scope explanation is NOT.
  * bad-ref   a gitlink naming a commit its (reachable, same-owner) remote lacks:
              git's real error is shown, the owner-scope explanation is NOT.

In every scenario the token never appears in the output. The server is real so
that "authentication failed" is an actual 401 from an actual git client, not a
string we wrote. The token is a constant that authenticates nothing.
"""

import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "provision-reprobuild-siblings.sh"
SERVER = ROOT / "git-auth" / "git-http-auth-server.py"
TOKEN = "ghs_TESTONLYnotarealtoken0000000000000000"
SIBLINGS = (
    "runquota", "nim-stackable-hooks", "io-mon", "nim-shm-lease", "nim-shm-queue",
    "nim-shm-gset", "reprobuild-test-adapters", "reprobuild-ct-test-runner",
    "reprobuild-llm-agent-packages",
)
NIM_LIBS = ("nim-serialization", "nim-faststreams", "nim-json-serialization",
            "nim-stew", "nimcrypto")
HEADLINE = "source-only Nim submodules failed"
OWNER_SCOPE = "cannot be authenticated by it"
BOUNDED = "last lines of git's output (at most 40)"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="submodule-failure-") as directory:
    root = Path(directory)
    home = root / "home"
    home.mkdir()
    config = home / ".gitconfig"
    config.touch()
    env = {key: value for key, value in os.environ.items()
            if not key.startswith("GIT_CONFIG") and key not in ("GIT_AUTH_DIR", "GITHUB_ACTION_PATH")}
    env.update(HOME=str(home), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1",
                GIT_CEILING_DIRECTORIES=str(root), LC_ALL="C")
    srv = root / "srv"

    def publish(bare, files, gitlinks=()):
        work = root / "build" / bare.replace("/", "_")
        run("git", "init", "-q", "-b", "dev", str(work), env=env)
        for name, content in files.items():
            (work / name).write_text(content)
            run("git", "-C", str(work), "add", name, env=env)
        for path, sha in gitlinks:
            run("git", "-C", str(work), "update-index", "--add", "--cacheinfo",
                f"160000,{sha},{path}", env=env)
        run("git", "-C", str(work), "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-qm", bare, env=env)
        run("git", "init", "-q", "--bare", "-b", "dev", str(srv / bare), env=env)
        run("git", "-C", str(work), "push", "-q", str(srv / bare), "dev", env=env)
        return run("git", "-C", str(work), "rev-parse", "HEAD", env=env).stdout.strip()

    for name in SIBLINGS:
        publish(f"fixture/{name}.git", {"README": f"{name}\n"})
    lib_sha = publish("fixture/nimlib.git", {"README": "nimlib\n"})
    publish("other/privatelib.git", {"README": "private\n"})

    def codetracer(url, sha=lib_sha):
        publish("fixture/codetracer.git", {
            "README": "codetracer\n",
            ".gitmodules": "".join(
                f'[submodule "libs/{lib}"]\n\tpath = libs/{lib}\n\turl = {url}\n'
                for lib in NIM_LIBS),
        }, [(f"libs/{lib}", sha) for lib in NIM_LIBS])

    (root / "token").write_text(TOKEN)
    server = subprocess.Popen(
        ["python3", str(SERVER), "--root", str(srv), "--journal", str(root / "journal"),
          "--auth-prefix", "/other/", "--auth-file", str(root / "token")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        port_line = server.stdout.readline().split()
        assert port_line and port_line[0] == "PORT", "the git server did not start"
        base = f"http://127.0.0.1:{port_line[1]}/"
        run("git", "config", "--file", str(config), f"url.{base}.insteadOf",
            "https://github.com/", env=env)
        run("git", "config", "--file", str(config), "protocol.file.allow", "always", env=env)

        def provision(case):
            workspace = root / case / "workspace"
            workspace.mkdir(parents=True)
            result = subprocess.run(
                ["bash", str(SCRIPT)], cwd=root, text=True, capture_output=True,
                env=dict(env, GH_TOKEN=TOKEN, GIT_AUTH_URL_BASE=base,
                          RUNNER_OS="Windows", RUNNER_TEMP=str(root),
                          SIBLING_OWNER="fixture", GITHUB_WORKSPACE=str(workspace)))
            output = result.stdout + result.stderr
            assert TOKEN not in output, f"{case}: the token was printed"
            assert result.returncode == 1, f"{case}: rc={result.returncode}\n{output}"
            assert HEADLINE in output, f"{case}: no failure message\n{output}"
            assert BOUNDED in output, f"{case}: git's output was not shown\n{output}"
            assert not list(root.glob("codetracer-submodules.*")), f"{case}: log file left behind"
            return output

        # auth: another owner, protected, and the scoped token does not cover it.
        codetracer("https://github.com/other/privatelib.git")
        out = provision("auth")
        assert OWNER_SCOPE in out, f"auth: the credential explanation was lost\n{out}"
        assert "submodule URL" in out and "/other/privatelib.git" in out, out
        print("PASS auth failure keeps the credential explanation and names the URL")

        # network: nothing listens on port 1 -- a transient-style failure.
        codetracer("http://127.0.0.1:1/fixture/nimlib.git")
        out = provision("network")
        assert OWNER_SCOPE not in out, f"network: blamed the credential\n{out}"
        assert "127.0.0.1" in out and "onnect" in out, f"network: real error missing\n{out}"
        print("PASS network failure shows git's real error, not the credential message")

        # bad ref: the remote is reachable and same-owner but lacks the commit.
        codetracer("https://github.com/fixture/nimlib.git", sha="1" * 40)
        out = provision("bad-ref")
        assert OWNER_SCOPE not in out, f"bad-ref: blamed the credential\n{out}"
        assert "1" * 40 in out or "not our ref" in out or "did not contain" in out, out
        print("PASS bad ref shows git's real error, not the credential message")
    finally:
        server.kill()
        server.wait()
