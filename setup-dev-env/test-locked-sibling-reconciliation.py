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

    def assert_reason(self, result, reason):
        self.assertIn("setup-dev-env: locked sibling refusal reason=" + reason,
                      result.stderr)

    def test_published_clean_stale_checkout_reconciles_without_deletion(self):
        self.assertEqual(self.head(), self.old)
        marker = self.target / ".git" / "preserved-control"
        marker.write_text("must survive", encoding="utf-8")
        self.reconcile(True)
        self.assertEqual(self.head(), self.new)
        self.assertEqual(marker.read_text(encoding="utf-8"), "must survive")
        self.reconcile(True)

    def test_root_proof_ignores_unavailable_historical_submodule(self):
        # Real root/child repositories reproduce persistent-runner Git config.
        # An unrelated published root branch records a removed child commit;
        # the selected root commit still names the populated child's valid HEAD.
        self.env["GIT_ALLOW_PROTOCOL"] = "file"
        child_seed = self.base / "child-seed"
        child_remote = self.base / "child.git"
        self.git("init", "-q", str(child_seed))
        for key, value in [("user.name", "Control"),
                            ("user.email", "control@example.invalid"),
                            ("commit.gpgsign", "false"),
                            ("core.hooksPath", str(self.home))]:
            self.git("-C", str(child_seed), "config", key, value)
        (child_seed / "retained").write_text("child source", encoding="utf-8")
        self.git("-C", str(child_seed), "add", "retained")
        self.git("-C", str(child_seed), "commit", "-qm", "child source")
        self.git("clone", "--bare", "-q", str(child_seed), str(child_remote))
        parent_branch = self.git("-C", str(self.seed), "branch", "--show-current").strip()
        self.git("-C", str(self.seed), "submodule", "add", "-q",
                  child_remote.as_uri(), "child")
        self.git("-C", str(self.seed), "commit", "-qm", "declare child")
        self.old = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(self.seed), "push", "-q", "origin", "HEAD:refs/heads/main")
        self.git("-C", str(self.target), "fetch", "-q", "origin")
        self.git("-C", str(self.target), "checkout", "-q", self.old)
        self.git("-C", str(self.target), "submodule", "update", "--init", "-q")
        child = self.target / "child"
        self.git("-C", str(child), "switch", "-qc", "retained-child")
        child_head = self.git("-C", str(child), "rev-parse", "HEAD").strip()
        missing = "deadbeef" * 5
        self.git("-C", str(self.seed), "switch", "-qc", "historical-child")
        self.git("-C", str(self.seed), "update-index", "--cacheinfo",
                  "160000," + missing + ",child")
        self.git("-C", str(self.seed), "commit", "-qm", "historical unavailable child")
        self.git("-C", str(self.seed), "push", "-q", "origin",
                  "HEAD:refs/heads/historical-child")
        self.git("-C", str(self.seed), "checkout", "--no-recurse-submodules",
                  "-q", parent_branch)
        self.commit("root-only update")
        self.new = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(self.seed), "push", "-q", "origin", "HEAD:refs/heads/main")
        (self.consumer / "repro.lock").write_text(
            'schema = "reprobuild.solved-graph-lock.v3"\n'
            'deps = [{ name = "dependency", url = "' + self.remote.as_uri() +
            '", revision = "' + self.new + '" }]\n', encoding="utf-8")
        self.git("-C", str(self.target), "config", "fetch.recurseSubmodules", "true")
        self.git("-C", str(self.target), "config", "submodule.recurse", "true")
        self.assertEqual(self.git("-C", str(self.target), "status", "--porcelain"), "")
        result = self.reconcile(True)
        self.assertEqual(self.head(), self.new)
        self.assertEqual(self.git("-C", str(child), "rev-parse", "HEAD").strip(), child_head)
        self.assertEqual(self.git("-C", str(child), "branch", "--show-current").strip(),
                          "retained-child")
        self.assertEqual((child / "retained").read_text(), "child source")
        self.assertNotIn("Fetching submodule", result.stdout + result.stderr)
        self.assertNotEqual(subprocess.run(
            ["git", "-C", str(child), "cat-file", "-e", missing], env=self.env,
            capture_output=True).returncode, 0)

        # Even when the selected root's gitlink changes, this root-only guard
        # must not acquire or check out child source. Child realization belongs
        # to the source materializer, not this publication/ownership proof.
        (child_seed / "retained").write_text("next child source", encoding="utf-8")
        self.git("-C", str(child_seed), "add", "retained")
        self.git("-C", str(child_seed), "commit", "-qm", "next child source")
        child_next = self.git("-C", str(child_seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(child_seed), "push", "-q", child_remote.as_uri(),
                  "HEAD:refs/heads/main")
        self.git("-C", str(self.seed), "update-index", "--cacheinfo",
                  "160000," + child_next + ",child")
        self.git("-C", str(self.seed), "commit", "-qm", "select next child")
        self.new = self.git("-C", str(self.seed), "rev-parse", "HEAD").strip()
        self.git("-C", str(self.seed), "push", "-q", "origin", "HEAD:refs/heads/main")
        (self.consumer / "repro.lock").write_text(
            'schema = "reprobuild.solved-graph-lock.v3"\n'
            'deps = [{ name = "dependency", url = "' + self.remote.as_uri() +
            '", revision = "' + self.new + '" }]\n', encoding="utf-8")
        self.reconcile(True)
        self.assertEqual(self.head(), self.new)
        self.assertEqual(self.git("-C", str(child), "rev-parse", "HEAD").strip(), child_head)
        self.assertEqual(self.git("-C", str(child), "branch", "--show-current").strip(),
                          "retained-child")
        self.assertEqual((child / "retained").read_text(), "child source")
        self.assertNotEqual(subprocess.run(
            ["git", "-C", str(child), "cat-file", "-e", child_next], env=self.env,
            capture_output=True).returncode, 0)

    def test_dirty_checkout_refuses_without_movement(self):
        (self.target / "payload").write_text("valuable edit", encoding="utf-8")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.target / "payload").read_text(), "valuable edit")
        self.assert_reason(result, "local-work")
        self.assertIn("setup-dev-env: locked sibling local-work:  M payload", result.stderr)
        self.assertNotIn("valuable edit", result.stdout + result.stderr)

    def test_untracked_checkout_refuses_without_movement(self):
        (self.target / "untracked").write_text("valuable", encoding="utf-8")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assertEqual((self.target / "untracked").read_text(), "valuable")
        self.assert_reason(result, "local-work")
        self.assertIn("setup-dev-env: locked sibling local-work: ?? untracked", result.stderr)
        self.assertNotIn("valuable", result.stdout + result.stderr)

    def test_selected_revision_still_refuses_local_work(self):
        self.git("-C", str(self.target), "fetch", "-q", "origin")
        self.git("-C", str(self.target), "checkout", "-q", "--detach", self.new)
        (self.target / "payload").write_text("private fixture body", encoding="utf-8")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.new)
        self.assertEqual((self.target / "payload").read_text(), "private fixture body")
        self.assert_reason(result, "local-work")
        self.assertNotIn("private fixture body", result.stdout + result.stderr)

    def test_failed_status_read_refuses_without_repairing_index(self):
        index = self.target / ".git" / "index"
        invalid = b"deliberately invalid fixture index"
        index.write_bytes(invalid)
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assertEqual(index.read_bytes(), invalid)
        self.assert_reason(result, "status-read")
        self.assertEqual(
            result.stderr,
            "setup-dev-env: locked sibling refusal reason=status-read\n",
        )
        self.assertNotIn(invalid.decode(), result.stdout + result.stderr)

    def test_status_metadata_is_git_quoted_bounded_and_content_free(self):
        # Real Git quotes this valid filename to more than the reporting cap.
        # No content, configuration or credential process stands in for Git.
        secret = "synthetic file content must never be logged"
        (self.target / ("é" * 100 + ".txt")).write_text(secret, encoding="utf-8")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "local-work")
        self.assertIn("path metadata omitted: longer than 512 characters", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

        quoted = self.target / "00 private path é.txt"
        quoted.write_text(secret, encoding="utf-8")
        for number in range(12):
            (self.target / f"entry-{number:02d}").write_text(secret, encoding="utf-8")
        expected = self.git("-c", "core.quotePath=true", "-C", str(self.target),
                            "status", "--porcelain", "--untracked-files=all").splitlines()
        self.assertEqual(len(expected), 14)
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assertEqual(quoted.read_text(encoding="utf-8"), secret)
        prefix = "setup-dev-env: locked sibling local-work: "
        lines = [line for line in result.stderr.splitlines() if line.startswith(prefix)]
        self.assertEqual(len(lines), 10)
        self.assertTrue(all(len(line) <= len(prefix) + 512 for line in lines))
        self.assertIn(prefix + expected[0], lines)
        self.assertIn("additional paths omitted: 4", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assert_reason(result, "local-work")

    def test_unpublished_head_refuses_without_movement(self):
        self.git("-C", str(self.target), "-c", "user.name=Control", "-c",
                  "user.email=control@example.invalid", "-c", "commit.gpgsign=false",
                  "-c", "core.hooksPath=" + str(self.home), "commit", "--allow-empty",
                  "-qm", "private")
        private = self.head()
        result = self.reconcile(False)
        self.assertEqual(self.head(), private)
        self.assert_reason(result, "unpublished-head")

    def test_deleted_remote_head_does_not_authorize_stale_tracking_ref(self):
        self.git("-C", str(self.seed), "push", "-q", "origin", ":refs/heads/main")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "unpublished-head")

    def test_rewritten_remote_head_does_not_authorize_stale_tracking_ref(self):
        self.git("-C", str(self.seed), "checkout", "--orphan", "replacement")
        self.commit("unrelated published history")
        self.git("-C", str(self.seed), "push", "-q", "--force", "origin",
                  "HEAD:refs/heads/main")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "unpublished-head")

    def test_narrow_refspec_cannot_preserve_an_orphan_tracking_ref(self):
        self.git("-C", str(self.target), "config", "remote.origin.fetch",
                  "+refs/heads/main:refs/remotes/origin/main")
        self.git("-C", str(self.target), "update-ref", "refs/remotes/origin/retired",
                  self.old)
        self.git("-C", str(self.seed), "checkout", "--orphan", "replacement")
        self.commit("rewritten remote")
        self.git("-C", str(self.seed), "push", "-q", "--force", "origin",
                  "HEAD:refs/heads/main")
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        refs = self.git("-C", str(self.target), "for-each-ref",
                        "--format=%(refname)", "refs/remotes/origin/")
        self.assertNotIn("refs/remotes/origin/retired", refs)
        self.assert_reason(result, "unpublished-head")

    def test_foreign_origin_refuses_without_movement(self):
        self.git("-C", str(self.target), "remote", "set-url", "origin",
                  (self.base / "foreign.git").as_uri())
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "origin-mismatch")

    def test_symlink_target_refuses(self):
        parked = self.base / "parked"
        self.target.rename(parked)
        self.target.symlink_to(parked, target_is_directory=True)
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "checkout-layout")

    def test_scope_escape_refuses(self):
        self.env["RUNNER_WORKSPACE"] = str(self.home)
        result = self.reconcile(False)
        self.assertEqual(self.head(), self.old)
        self.assert_reason(result, "runner-scope")


if __name__ == "__main__":
    unittest.main()
