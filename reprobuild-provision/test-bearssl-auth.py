"""No mocks: the status-im/nim-bearssl clone carries the CI credential on the wire.

`provision-reprobuild-siblings.sh` declares `<base>status-im/` as an extra
credential scope so that the one third-party clone on the Windows path, and its
`status-im/BearSSL` submodule, stop drawing on GitHub's per-IP anonymous budget.
The declaration is only worth something if the header actually REACHES those
fetches, and a PUBLIC repository never challenges, so the clone succeeding
proves nothing. This suite runs the real provisioner, Windows path, against
`git-auth/git-http-auth-server.py` and reads what arrived from the server's
journal:

  * `/fixture/` (the sibling owner) is protected: every sibling clone must
    authenticate with the token, exactly as on github.com.
  * `/status-im/` is public, as on github.com: the server journals
    `public-auth` when a credential arrived anyway and `public-noauth` when the
    fetch was anonymous. Every request for nim-bearssl and its BearSSL
    submodule must be `public-auth`.

MUTATION-VERIFIED: the same run with the `EXTRA_TOKEN_URL_PREFIXES` declaration
removed from a copy of the script must journal `public-noauth`, or the
assertion above would pass for a reason other than the declaration.

The pinned BearSSL revision is a real upstream SHA that no fixture can
reproduce, so the run is bounded by the pin step failing AFTER the clone, which
is asserted by its message. That the default scope does NOT cover status-im is
asserted separately, in `setup-nix/configure-git-auth-test.sh`.

The token is a constant that authenticates nothing; nothing here prints it.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "provision-reprobuild-siblings.sh"
SERVER = ROOT / "git-auth" / "git-http-auth-server.py"
TOKEN = "ghs_TESTONLYnotarealtoken0000000000000000"
SIBLINGS = (
    "runquota", "nim-stackable-hooks", "io-mon", "nim-shm-lease", "nim-shm-queue",
    "nim-shm-gset", "reprobuild-test-adapters", "reprobuild-ct-test-runner",
    "reprobuild-llm-agent-packages", "nimlib",
)
NIM_LIBS = ("nim-serialization", "nim-faststreams", "nim-json-serialization",
            "nim-stew", "nimcrypto")
DECLARATION = 'export EXTRA_TOKEN_URL_PREFIXES="${STATUS_IM_SCOPE}"\n'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="bearssl-auth-") as directory:
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

    def commit(work, message):
        run("git", "-C", str(work), "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-qm", message, env=env)
        return run("git", "-C", str(work), "rev-parse", "HEAD", env=env).stdout.strip()

    def publish(bare, branch, files, gitlinks=()):
        """Create `srv/<bare>` on `branch` with `files` and `(path, sha)` gitlinks."""
        work = root / "build" / bare.replace("/", "_")
        run("git", "init", "-q", "-b", branch, str(work), env=env)
        for name, content in files.items():
            (work / name).write_text(content)
            run("git", "-C", str(work), "add", name, env=env)
        for path, sha in gitlinks:
            # The gitlink is written directly: `submodule add` would have to
            # reach the URL in `.gitmodules`, which names github.com.
            run("git", "-C", str(work), "update-index", "--add", "--cacheinfo",
                f"160000,{sha},{path}", env=env)
        sha = commit(work, bare)
        run("git", "init", "-q", "--bare", "-b", branch, str(srv / bare), env=env)
        run("git", "-C", str(work), "push", "-q", str(srv / bare), branch, env=env)
        return sha

    lib_sha = None
    for name in SIBLINGS:
        lib_sha = publish(f"fixture/{name}.git", "dev", {"README": f"{name}\n"})
    # The five source-only Nim submodules, spelled scp-style as codetracer's
    # `.gitmodules` spells them, so the provisioner's ssh->https rewrites are
    # exercised on the way.
    publish("fixture/codetracer.git", "dev", {
        "README": "codetracer\n",
        ".gitmodules": "".join(
            f'[submodule "libs/{lib}"]\n\tpath = libs/{lib}\n'
            f"\turl = git@github.com:fixture/nimlib.git\n" for lib in NIM_LIBS),
    }, [(f"libs/{lib}", lib_sha) for lib in NIM_LIBS])
    # Spelled exactly as upstream nim-bearssl spells it: an https github.com URL
    # with no `.git` suffix. The sandbox's `insteadOf` below sends it here.
    bearssl_c = publish("status-im/BearSSL", "master", {"README": "BearSSL\n"})
    publish("status-im/nim-bearssl.git", "master", {
        "README": "nim-bearssl\n",
        ".gitmodules": '[submodule "bearssl/csources"]\n\tpath = bearssl/csources\n'
                        "\turl = https://github.com/status-im/BearSSL\n",
    }, [("bearssl/csources", bearssl_c)])

    (root / "token").write_text(TOKEN)
    journal = root / "journal"
    server = subprocess.Popen(
        ["python3", str(SERVER), "--root", str(srv), "--journal", str(journal),
          "--auth-prefix", "/fixture/", "--auth-file", str(root / "token")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        port_line = server.stdout.readline().split()
        assert port_line and port_line[0] == "PORT", "the git server did not start"
        base = f"http://127.0.0.1:{port_line[1]}/"
        run("git", "config", "--file", str(config), f"url.{base}.insteadOf",
            "https://github.com/", env=env)

        def provision(case, script, extra_env=None):
            journal.write_text("")
            workspace = root / case / "workspace"
            workspace.mkdir(parents=True)
            result = subprocess.run(
                ["bash", str(script)], cwd=root, text=True, capture_output=True,
                env=dict(env, GH_TOKEN=TOKEN, GIT_AUTH_URL_BASE=base,
                          RUNNER_OS="Windows", RUNNER_TEMP=str(root),
                          SIBLING_OWNER="fixture", GITHUB_WORKSPACE=str(workspace),
                         **(extra_env or {})))
            output = result.stdout + result.stderr
            assert TOKEN not in output, f"{case}: the token was printed"
            assert result.returncode == 1, f"{case}: rc={result.returncode}\n{output}"
            assert "pinning status-im/nim-bearssl to" in output, (
                f"{case}: the run did not get past the BearSSL clone\n{output}")
            bearssl = workspace / "nim-bearssl"
            assert (bearssl / "README").is_file(), f"{case}: nim-bearssl was not cloned"
            assert (bearssl / "bearssl" / "csources" / "README").is_file(), (
                f"{case}: the status-im/BearSSL submodule was not cloned")
            leaked = subprocess.run(["grep", "-rlF", TOKEN, str(workspace)],
                                    text=True, capture_output=True).stdout
            assert leaked == "", f"{case}: the token was written to disk: {leaked}"
            entries = [line.split(" ", 1) for line in journal.read_text().splitlines()]
            return output, entries

        def verdicts(entries, prefix):
            return {verdict for verdict, path in entries if path.startswith(prefix)}

        _, entries = provision("declared", SCRIPT)
        fixture = verdicts(entries, "/fixture/")
        assert fixture == {"ok"}, f"sibling clones were not all authenticated: {fixture}"
        print("PASS every fixture sibling clone authenticates with the token")
        for repo in ("/status-im/nim-bearssl.git/", "/status-im/BearSSL/"):
            seen = verdicts(entries, repo)
            assert seen == {"public-auth"}, (
                f"{repo}: expected every request to carry the credential, journal "
                f"said {seen or 'nothing'} -- the fetch drew on the anonymous budget")
            print(f"PASS {repo} is fetched WITH the credential, unchallenged")

        # MUTATION: the identical script without the declaration.
        source = SCRIPT.read_text()
        assert source.count(DECLARATION) == 1, "the declaration line moved; update this suite"
        mutant = root / "mutant.sh"
        mutant.write_text(source.replace(DECLARATION, ""))
        _, entries = provision("mutant", mutant, {
            "GITHUB_ACTION_PATH": str(HERE), "GIT_AUTH_DIR": str(ROOT / "git-auth")})
        for repo in ("/status-im/nim-bearssl.git/", "/status-im/BearSSL/"):
            seen = verdicts(entries, repo)
            assert seen == {"public-noauth"}, (
                f"mutation: {repo} without the declaration journalled {seen or 'nothing'}"
                " -- the assertion above cannot tell the declaration apart from its absence")
        print("PASS mutation: without the declaration both status-im fetches are anonymous")
    finally:
        server.kill()
        server.wait()
