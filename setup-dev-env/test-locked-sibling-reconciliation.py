#!/usr/bin/env python3
"""Real Git controls for persistent CI sibling reconciliation.

The fixture uses an actual local bare remote and checkout; no Git, Repro or
credential process is mocked. It tests the shared action's pre-adoption boundary,
not Windows provisioning or Repro's independently owned materializer.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LockedSiblingReconciliation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="locked-sibling-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.scope = self.base / "runner"
        self.scope.mkdir()
        self.consumer = self.scope / "consumer"
        self.consumer.mkdir()
        self.remote = self.base / "remote.git"
        self.seed = self.base / "seed"
        self.target = self.scope / "dependency"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "GH_", "GITHUB_", "SSH_"))}
        self.env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TEMPLATE_DIR="",
                        GITHUB_ACTIONS="true", RUNNER_WORKSPACE=str(self.scope))
        self.git("init", "--bare", "-q", str(self.remote))
        self.git("init", "-q", str(self.seed))
        self.git("-C", str(self.seed), "config", "user.name", "Control")
        self.git("-C", str(self.seed), "config", "user.email", "control@example.invalid")
        self.git("-C", str(self.seed), "config", "commit.gpgsign", "false")
        self.git("-C", str(self.seed), "config", "core.hooksPath", str(self.home))
        self.commit("first")
        self.old = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(self.seed), "remote", "add", "origin", self.remote.as_uri())
        self.git("-C", str(self.seed), "push", "-q", "origin", "HEAD:refs/heads/main")
        self.git("clone", "-q", "--branch", "main", self.remote.as_uri(), str(self.target))
        self.commit("second")
        self.new = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(self.seed), "push", "-q", "origin", "HEAD:refs/heads/main")
        (self.consumer / "repro.lock").write_text(
            'schema = "reprobuild.solved-graph-lock.v3"\n'
            'deps = [{ name = "dependency", url = "' + self.remote.as_uri() +
            '", revision = "' + self.new + '" }]\n', encoding="utf-8")

    def git(self, *args):
        return subprocess.run(["git", *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def commit(self, value):
        (self.seed / "payload").write_text(value, encoding="utf-8")
        self.git("-C", str(self.seed), "add", "payload")
        self.git("-C", str(self.seed), "commit", "-qm", value)

    def reconcile(self, success):
        command = ('source "$1/git-auth/scoped-git-auth.sh"; '
                    'source "$1/setup-dev-env/reconcile-locked-sibling.sh"; '
                    'reconcile_locked_sibling "$2" dependency "$3" "$4"')
        result = subprocess.run(["bash", "-c", command, "control", str(ROOT),
                                  str(self.consumer), self.new, str(self.target)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def head(self):
        return self.git("-C", str(self.target), "rev-parse", "HEAD").strip()

    def test_published_clean_stale_checkout_reconciles_without_deletion(self):
        self.assertEqual(self.head(), self.old)
        marker = self.target / ".git" / "preserved-control"
        marker.write_text("must survive", encoding="utf-8")
        self.reconcile(True)
        self.assertEqual(self.head(), self.new)
        self.assertEqual(marker.read_text(encoding="utf-8"), "must survive")
        self.reconcile(True)

    def test_dirty_checkout_refuses_without_movement(self):
        (self.target / "payload").write_text("valuable edit", encoding="utf-8")
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.target / "payload").read_text(), "valuable edit")

    def test_untracked_checkout_refuses_without_movement(self):
        (self.target / "untracked").write_text("valuable", encoding="utf-8")
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)

    def test_unpublished_head_refuses_without_movement(self):
        self.git("-C", str(self.target), "-c", "user.name=Control", "-c",
                  "user.email=control@example.invalid", "-c", "commit.gpgsign=false",
                  "-c", "core.hooksPath=" + str(self.home), "commit", "--allow-empty",
                  "-qm", "private")
        private = self.head()
        self.reconcile(False)
        self.assertEqual(self.head(), private)

    def test_deleted_remote_head_does_not_authorize_stale_tracking_ref(self):
        self.git("-C", str(self.seed), "push", "-q", "origin", ":refs/heads/main")
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)

    def test_rewritten_remote_head_does_not_authorize_stale_tracking_ref(self):
        self.git("-C", str(self.seed), "checkout", "--orphan", "replacement")
        self.commit("unrelated published history")
        self.git("-C", str(self.seed), "push", "-q", "--force", "origin",
                  "HEAD:refs/heads/main")
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)

    def test_narrow_refspec_cannot_preserve_an_orphan_tracking_ref(self):
        self.git("-C", str(self.target), "config", "remote.origin.fetch",
                  "+refs/heads/main:refs/remotes/origin/main")
        self.git("-C", str(self.target), "update-ref", "refs/remotes/origin/retired",
                  self.old)
        self.git("-C", str(self.seed), "checkout", "--orphan", "replacement")
        self.commit("rewritten remote")
        self.git("-C", str(self.seed), "push", "-q", "--force", "origin",
                  "HEAD:refs/heads/main")
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        refs = self.git("-C", str(self.target), "for-each-ref",
                        "--format=%(refname)", "refs/remotes/origin/")
        self.assertNotIn("refs/remotes/origin/retired", refs)

    def test_foreign_origin_refuses_without_movement(self):
        self.git("-C", str(self.target), "remote", "set-url", "origin",
                  (self.base / "foreign.git").as_uri())
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)

    def test_symlink_target_refuses(self):
        parked = self.base / "parked"
        self.target.rename(parked)
        self.target.symlink_to(parked, target_is_directory=True)
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)

    def test_scope_escape_refuses(self):
        self.env["RUNNER_WORKSPACE"] = str(self.home)
        self.reconcile(False)
        self.assertEqual(self.head(), self.old)


if __name__ == "__main__":
    unittest.main()
