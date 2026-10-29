#!/usr/bin/env python3
"""Exercise the immutable-source handoff through real Git and the shipped clone.

Only Repro's structured selection is stubbed: this action-routing suite must run
without building the SDK it provisions. The pinned/state fields match shipped
v0.2.17's develop-list schema. All lock reading, clone resolution, Git objects,
branches and checkout bytes are real. A URL-only Git shim replaces GitHub transport
so the control needs no network or credentials; the remote tip deliberately
advances beyond the committed pin to detect mutable/default selection.
"""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FrozenSiblingSource(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="frozen-sibling-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.consumer = self.base / "runner" / "consumer"
        self.consumer.mkdir(parents=True)
        self.home = self.base / "home"
        self.home.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "GH_", "GITHUB_", "SSH_"))}
        self.env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TEMPLATE_DIR="",
                        GIT_ALLOW_PROTOCOL="file", GH_TOKEN="",
                        GITHUB_WORKSPACE=str(self.consumer),
                        GITHUB_REPOSITORY="metacraft-labs/consumer",
                        GITHUB_SHA="a" * 40, GITHUB_EVENT_NAME="workflow_dispatch",
                        RUNNER_TEMP=str(self.base), SIBLING_OWNER="metacraft-labs",
                        JOB_TOKEN_OWNERS="metacraft-labs", LOCK_STORE="committed",
                        GIT_AUTH_DIR=str(ROOT / "git-auth"),
                        GITHUB_OUTPUT=str(self.base / "output"),
                        GITHUB_ENV=str(self.base / "env"),
                        GITHUB_STEP_SUMMARY=str(self.base / "summary"))
        self.seed = self.base / "seed"
        self.git("init", "-q", "-b", "dev", str(self.seed))
        for key, value in [("user.name", "Control"),
                            ("user.email", "control@example.invalid"),
                            ("commit.gpgsign", "false"),
                            ("core.hooksPath", str(self.home))]:
            self.git("-C", str(self.seed), "config", key, value)
        self.commit("locked source")
        self.pin = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.commit("new branch tip")
        self.tip = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.assertNotEqual(self.pin, self.tip)
        server = self.base / "server" / "metacraft-labs"
        server.mkdir(parents=True)
        self.git("clone", "--bare", "-q", str(self.seed), str(server / "dependency.git"))
        # Transport-only shim: actual Git receives every flag unchanged, while
        # logical GitHub remotes resolve to our real local bare fixture.
        real_git = shutil.which("git")
        wrapper = self.bin / "git"
        wrapper.write_text(
            '#!/usr/bin/env bash\nargs=()\nfor arg in "$@"; do\n'
            ' case "$arg" in https://github.com/*) '
            'args+=("file://' + str(self.base / "server") + '/${arg#https://github.com/}") ;;\n'
            ' *) args+=("$arg") ;; esac\ndone\nexec "' + real_git + '" "${args[@]}"\n')
        wrapper.chmod(0o755)
        (self.consumer / "repro.lock").write_text(
            'schema = "reprobuild.solved-graph-lock.v3"\n[lock]\n'
            'deps = [{ name = "dependency", coord_kind = "vcs", '
            'url = "https://github.com/metacraft-labs/dependency", '
            'revision = "' + self.pin + '", integrity = "git-sha1:' + self.pin + '" }]\n')
        repro = self.bin / "repro"
        repro.write_text('#!/usr/bin/env bash\nset -eu\n'
                          'case "$*" in\n'
                          '"develop --list --json") cat "$CONTROL_LIST" ;;\n'
                          '"develop --all") : ;;\n'
                          '*) exit 91 ;;\nesac\n')
        repro.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]

    def git(self, *args):
        return subprocess.run(["git", *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def commit(self, text):
        (self.seed / "payload").write_text(text)
        self.git("-C", str(self.seed), "add", "payload")
        self.git("-C", str(self.seed), "commit", "-qm", text)

    def provision(self, declared, state="pinned", success=True, name="dependency"):
        listing = {"schemaId": "reprobuild.develop-list.v1", "exitCode": 0,
                    "repos": [{"name": name, "backend": "committed-lock",
                              "revision": self.pin,
                              "path": str(self.consumer.parent / name),
                              "state": state, "pinnedByRecipe": "flake.nix:7"}],
                    "backends": [{"kind": "committed-lock", "reachable": True,
                                  "records": 1, "location": str(self.consumer / "repro.lock")}],
                    "errors": []}
        source = self.base / "list.json"
        source.write_text(json.dumps(listing, indent=2) + "\n")
        env = dict(self.env, CONTROL_LIST=str(source), SIBLING_STRATEGY="repro-lock",
                    SIBLINGS_INPUT=declared)
        result = subprocess.run(["bash", str(ROOT / "setup-dev-env/provision-siblings-from-lock.sh")],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if not success:
            return result.stdout + result.stderr
        return (self.base / "output").read_text()

    def clone_handoff(self, declared, name="dependency"):
        output = self.provision(declared, name=name)
        self.assertIn("late-clone=true\n", output)
        marker = "late-siblings<<__SETUP_DEV_ENV_EOF__\n"
        siblings = output.split(marker, 1)[1].split("__SETUP_DEV_ENV_EOF__", 1)[0]
        self.assertNotIn("=dev", siblings)
        env = dict(self.env, SIBLINGS_INPUT=siblings,
                    GITHUB_ACTION_PATH=str(ROOT / "clone-siblings"))
        result = subprocess.run(["bash", str(ROOT / "clone-siblings/clone-siblings.sh")],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        target = self.consumer.parent / name
        self.assertEqual(self.git("-C", str(target), "rev-parse", "HEAD").strip(), self.pin)
        self.assertEqual((target / "payload").read_text(), "locked source")
        self.assertFalse((self.consumer / ".repro/develop-overrides.json").exists())

    def test_declared_pinned_source_uses_real_locked_clone_not_branch_tip(self):
        self.clone_handoff("dependency")

    def test_declared_mutable_ref_cannot_replace_immutable_source(self):
        self.clone_handoff("dependency=dev")

    def test_selected_name_case_is_preserved_for_lock_lookup_and_destination(self):
        lock = self.consumer / "repro.lock"
        lock.write_text(lock.read_text().replace("dependency", "Dependency"))
        remote = self.base / "server/metacraft-labs/dependency.git"
        remote.rename(remote.with_name("Dependency.git"))
        self.clone_handoff("Dependency", name="Dependency")

    def test_record_store_cannot_replace_selected_committed_source(self):
        action = (ROOT / "setup-dev-env/action.yml").read_text()
        step = action.split("id: repro-siblings", 1)[1].split("    - name:", 1)[0]
        self.assertIn("LOCK_STORE: ${{ inputs.lock-store }}", step)
        self.env["LOCK_STORE"] = "record-store"
        result = self.provision("dependency", success=False)
        self.assertIn("requires lock-store: committed", result)
        self.assertFalse((self.consumer.parent / "dependency").exists())

    def test_alias_cannot_select_another_locked_rows_revision(self):
        lock = self.consumer / "repro.lock"
        text = lock.read_text().replace(
            'url = "https://github.com/metacraft-labs/dependency"',
            'url = "https://github.com/metacraft-labs/other"')
        text = text.replace(' }]\n',
                            ' }, { name = "other", revision = "' + self.tip +
                            '", integrity = "git-sha1:' + self.tip + '" }]\n')
        lock.write_text(text)
        self.assertIn('name = "other"', text)
        self.assertIn(self.tip, text)
        result = self.provision("dependency", success=False)
        self.assertIn("basename equals the selected name", result)
        self.assertFalse((self.consumer.parent / "dependency").exists())
        self.assertFalse((self.consumer.parent / "other").exists())

    def test_undeclared_pinned_row_is_not_added_to_clone_set(self):
        self.assertIn("late-clone=false\n", self.provision(""))

    def test_develop_materialized_row_remains_redundant(self):
        self.assertIn("late-clone=false\n", self.provision("dependency", state="absent"))


if __name__ == "__main__":
    unittest.main()
