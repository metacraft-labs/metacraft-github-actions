#!/usr/bin/env python3
"""Contract tests for tools/check-pins.py (local mode only, no network).

No mocks: each case writes real pin files into a temporary directory next to
the real schema and runs the real script as a subprocess. The remote checks
need a private repository and a token, and are exercised by the `pins`
workflow itself.
"""

import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOOD = {
    "schema": 1, "tool": "demo", "owner": "some-owner", "repo": "some-repo",
    "rev": "0123456789abcdef0123456789abcdef01234567",
    "narHash": "sha256-" + "A" * 43 + "=",
}


def workflow_step(workflow, name):
    """The text of the pins.yml step called `name`, up to the next step."""
    start = workflow.index(f"      - name: {name}\n")
    end = workflow.find("\n      - ", start + 1)
    return workflow[start:] if end < 0 else workflow[start:end]


def owner_token_narrowing_defects(workflow):
    """What lets the `remote` job's owner token reach beyond contents:read on
    the owner's pinned repositories (pins/README.md, "Tokens"); empty when
    nothing does."""
    defects = []
    repos = workflow_step(workflow, "The owner's pinned repositories")
    mint = workflow_step(workflow, "Mint a read token for the owner")
    if workflow.index(repos) > workflow.index(mint):
        defects.append("the repositories are listed after the token is minted")
    if "        id: repos\n" not in repos:
        defects.append("the listing step is not `repos`")
    # An assignment fails the step under `bash -e` when the listing fails or
    # prints nothing; an empty `repositories:` input would widen the token.
    if ('          repos="$(python3 -I tools/check-pins.py --list-repos --owner "$OWNER")"\n'
            '          echo "repos=$repos" | tee -a "$GITHUB_OUTPUT"') not in repos:
        defects.append("the listing does not fail the step when check-pins.py fails")
    if "continue-on-error" in repos or "continue-on-error" in mint:
        defects.append("a failure of the listing or the minting is tolerated")
    if "          owner: ${{ matrix.owner }}\n" not in mint:
        defects.append("the token is not minted for the leg's owner")
    if "          repositories: ${{ steps.repos.outputs.repos }}\n" not in mint:
        defects.append("the token is not limited to the listed repositories")
    permissions = [
        line.strip() for line in mint.splitlines() if line.strip().startswith("permission-")]
    if permissions != ["permission-contents: read"]:
        defects.append(f"the token's permissions are {permissions}, not contents:read alone")
    return defects


class CheckPins(unittest.TestCase):
    def run_with(self, **files):
        with tempfile.TemporaryDirectory() as tmp:
            pins = pathlib.Path(tmp)
            shutil.copy(ROOT / "pins" / "pin.schema.json", pins)
            for name, body in files.items():
                (pins / f"{name}.json").write_text(
                    body if isinstance(body, str) else json.dumps(body))
            done = subprocess.run(
                [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py"),
                  "--pins-dir", str(pins)], capture_output=True, text=True)
            return done.returncode, done.stdout + done.stderr

    def test_the_real_pins_pass(self):
        done = subprocess.run(
            [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py")],
            capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_good_pin_passes(self):
        code, out = self.run_with(demo=GOOD)
        self.assertEqual(code, 0, out)

    def test_attrs_and_flake_are_accepted(self):
        code, out = self.run_with(demo={**GOOD, "flake": False, "attrs": {"a": "b"}})
        self.assertEqual(code, 0, out)

    def test_systems_must_be_known_and_nonempty(self):
        for systems in ([], ["vax"], "x86_64-linux"):
            code, _ = self.run_with(demo={**GOOD, "systems": systems})
            self.assertEqual(code, 1, systems)
        code, out = self.run_with(demo={**GOOD, "systems": ["x86_64-linux"]})
        self.assertEqual(code, 0, out)

    def test_tool_must_equal_the_file_name(self):
        code, out = self.run_with(other=GOOD)
        self.assertEqual(code, 1)
        self.assertIn("must equal the file name", out)

    def test_unknown_field_is_rejected(self):
        code, out = self.run_with(demo={**GOOD, "revv": "x"})
        self.assertEqual(code, 1)
        self.assertIn("unknown field 'revv'", out)

    def test_missing_required_field_is_rejected(self):
        bad = {k: v for k, v in GOOD.items() if k != "narHash"}
        code, out = self.run_with(demo=bad)
        self.assertEqual(code, 1)
        self.assertIn("missing required field 'narHash'", out)

    def test_a_branch_is_not_a_rev(self):
        code, out = self.run_with(demo={**GOOD, "rev": "agents"})
        self.assertEqual(code, 1)
        self.assertIn("rev", out)

    def test_a_short_or_uppercase_rev_is_rejected(self):
        for rev in (GOOD["rev"][:39], GOOD["rev"].upper()):
            code, _ = self.run_with(demo={**GOOD, "rev": rev})
            self.assertEqual(code, 1, rev)

    def test_a_non_sri_hash_is_rejected(self):
        code, _ = self.run_with(demo={**GOOD, "narHash": "sha1-" + "A" * 27})
        self.assertEqual(code, 1)

    def test_wrong_schema_version_is_rejected(self):
        code, _ = self.run_with(demo={**GOOD, "schema": 2})
        self.assertEqual(code, 1)

    def test_a_boolean_is_not_the_schema_integer(self):
        code, _ = self.run_with(demo={**GOOD, "schema": True})
        self.assertEqual(code, 1)

    def test_attrs_values_must_be_nonempty_strings(self):
        for attrs in ({"a": ""}, {"a": 3}):
            code, _ = self.run_with(demo={**GOOD, "attrs": attrs})
            self.assertEqual(code, 1, attrs)

    def test_invalid_json_is_a_failure_not_a_crash(self):
        code, out = self.run_with(demo="{not json")
        self.assertEqual(code, 1)
        self.assertIn("cannot be read as JSON", out)

    def test_version_and_kind_come_together(self):
        for extra in ({"version": "1.2.3"}, {"kind": "agents-commit"}):
            code, out = self.run_with(demo={**GOOD, **extra})
            self.assertEqual(code, 1, extra)
            self.assertIn("version and kind must be given together", out)
        code, out = self.run_with(demo={**GOOD, "version": "1.2.3", "kind": "release"})
        self.assertEqual(code, 0, out)

    def test_kind_and_version_values_are_checked(self):
        for extra in ({"version": "1.2.3", "kind": "branch"},
                      {"version": "dev", "kind": "agents-commit"}):
            code, _ = self.run_with(demo={**GOOD, **extra})
            self.assertEqual(code, 1, extra)

    def test_the_owners_are_listed_for_the_token_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            pins = pathlib.Path(tmp)
            shutil.copy(ROOT / "pins" / "pin.schema.json", pins)
            for name, owner in (("demo", "b-owner"), ("other", "a-owner"), ("third", "b-owner")):
                (pins / f"{name}.json").write_text(json.dumps({**GOOD, "tool": name, "owner": owner}))
            done = subprocess.run(
                [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py"),
                  "--pins-dir", str(pins), "--list-owners"], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(done.stdout), ["a-owner", "b-owner"])
            done = subprocess.run(
                [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py"),
                  "--pins-dir", str(pins), "--owner", "nobody"], capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)

    def test_each_owners_repositories_are_listed_for_its_token(self):
        # Each owner's token is limited to the repositories its pins name.
        with tempfile.TemporaryDirectory() as tmp:
            pins = pathlib.Path(tmp)
            shutil.copy(ROOT / "pins" / "pin.schema.json", pins)
            for name, owner, repo in (("demo", "b-owner", "zeta"), ("other", "a-owner", "solo"),
                                      ("third", "b-owner", "alpha"), ("fourth", "b-owner", "zeta")):
                (pins / f"{name}.json").write_text(
                    json.dumps({**GOOD, "tool": name, "owner": owner, "repo": repo}))
            def list_repos(*extra):
                return subprocess.run(
                    [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py"),
                      "--pins-dir", str(pins), "--list-repos", *extra],
                    capture_output=True, text=True)
            done = list_repos("--owner", "b-owner")
            self.assertEqual((done.returncode, done.stdout), (0, "alpha,zeta\n"), done.stderr)
            done = list_repos("--owner", "a-owner")
            self.assertEqual((done.returncode, done.stdout), (0, "solo\n"), done.stderr)
            self.assertEqual(list_repos("--owner", "nobody").returncode, 1)
            self.assertEqual(list_repos().returncode, 2)
            self.assertEqual(list_repos("--owner", "a-owner", "--remote").returncode, 2)

    def test_the_owner_token_is_narrowed_to_contents_read_on_the_pinned_repositories(self):
        # The CI token provider App's agent-harbor installation covers every
        # repository of the organization (pins/README.md, "Tokens"), so the
        # minting step's inputs are the only limit on the owner's token: the
        # repositories --list-repos prints, and contents:read and no other
        # permission. A text check, because the steps run only in Actions.
        workflow = (ROOT / ".github" / "workflows" / "pins.yml").read_text()
        self.assertEqual(owner_token_narrowing_defects(workflow), [])
        # Negative controls: each way of widening the token is reported.
        widened = {
            "no repositories": ("          repositories: ${{ steps.repos.outputs.repos }}\n", ""),
            "a second permission": ("          permission-contents: read\n",
                                    "          permission-contents: read\n"
                                    "          permission-pull-requests: write\n"),
            "no permission": ("          permission-contents: read\n", ""),
            "write access": ("permission-contents: read", "permission-contents: write"),
            "another owner": ("          owner: ${{ matrix.owner }}\n          repositories",
                              "          owner: metacraft-labs\n          repositories"),
            "an echo that hides a failed listing": (
                '          repos="$(python3 -I tools/check-pins.py --list-repos --owner "$OWNER")"\n'
                '          echo "repos=$repos"',
                '          echo "repos=$(python3 -I tools/check-pins.py --list-repos --owner "$OWNER")"'),
            "a listing that may fail": ("        id: repos\n",
                                        "        id: repos\n        continue-on-error: true\n"),
        }
        for why, (old, new) in widened.items():
            with self.subTest(why):
                self.assertEqual(workflow.count(old), 1, old)
                self.assertNotEqual(
                    owner_token_narrowing_defects(workflow.replace(old, new)), [], why)

    def test_each_owner_gets_its_own_token(self):
        # The workflow mints one token per owner; a pin is checked with its
        # owner's token, handed to gh and nix only through the environment.
        spec = importlib.util.spec_from_file_location("check_pins", ROOT / "tools" / "check-pins.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(saved)))
        for name in [k for k in os.environ if k.startswith("GH_TOKEN") or k == "NIX_CONFIG"]:
            del os.environ[name]
        os.environ.update(GH_TOKEN="fallback", GH_TOKEN_AGENT_HARBOR="harbor")
        env = module.token_environment("agent-harbor")
        self.assertEqual(env["GH_TOKEN"], "harbor")
        self.assertEqual(env["NIX_CONFIG"], "access-tokens = github.com=harbor")
        env = module.token_environment("metacraft-labs")
        self.assertEqual(env["GH_TOKEN"], "fallback")
        os.environ["NIX_CONFIG"] = "sandbox = true"
        env = module.token_environment("agent-harbor")
        self.assertEqual(env["NIX_CONFIG"], "sandbox = true\naccess-tokens = github.com=harbor")
        del os.environ["GH_TOKEN"], os.environ["NIX_CONFIG"]
        env = module.token_environment("metacraft-labs")
        self.assertNotIn("GH_TOKEN", env)
        self.assertNotIn("NIX_CONFIG", env)

    def test_an_empty_directory_is_a_usage_error(self):
        code, _ = self.run_with()
        self.assertEqual(code, 2)


WORKFLOW = ROOT / ".github" / "workflows" / "pins.yml"


def workflow_job(workflow, job):
    """The text of the pins.yml job `job`, up to the next job."""
    start = workflow.index(f"\n  {job}:\n") + 1
    end = workflow.find("\n  ", start + 1)
    while end >= 0 and workflow[end + 3] in " #":
        end = workflow.find("\n  ", end + 1)
    return workflow[start:] if end < 0 else workflow[start:end]


def gate_script(workflow):
    """The Python `pins-gate` runs, exactly as the step's heredoc holds it."""
    step = workflow_step(workflow, "Every needed job passed")
    body = step[step.index("<<'PY'\n") + len("<<'PY'\n"):step.index("\n          PY")]
    return textwrap.dedent(body) + "\n"


class PinsGate(unittest.TestCase):
    """The `pins-gate` step's own Python, run on the `needs` context Actions
    would hand it. The script is executed as written in pins.yml, so a change
    to the gate is what these cases measure."""

    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()
        cls.script = gate_script(cls.workflow)

    def needs(self, codetracer=True, mac=("success", "confirmed")):
        flags = {"pins": "true", "reprobuild": "false", "codetracer": str(codetracer).lower()}
        needs = {
            "changes": {"result": "success", "outputs": dict(flags, owners='["metacraft-labs"]')},
            "local": {"result": "success", "outputs": {}},
            "resolver-windows": {"result": "skipped", "outputs": {}},
            "remote": {"result": "success", "outputs": {}},
            "reprobuild-package": {"result": "skipped", "outputs": {}},
            "setup-reprobuild": {"result": "skipped", "outputs": {}},
        }
        if mac is not None:
            result, outcome = mac
            needs["codetracer-mac-lock"] = {
                "result": result, "outputs": {} if outcome is None else {"outcome": outcome}}
        return needs

    def gate(self, needs):
        done = subprocess.run(
            [sys.executable, "-I", "-"], input=self.script, capture_output=True, text=True,
            env=dict(os.environ, NEEDS=json.dumps(needs)), check=False)
        return done.returncode, done.stdout + done.stderr

    def test_the_lock_job_is_in_the_gates_needs_and_runs_only_for_codetracer_changes(self):
        gate = workflow_job(self.workflow, "pins-gate")
        self.assertIn("        codetracer-mac-lock,\n", gate)
        job = workflow_job(self.workflow, "codetracer-mac-lock")
        self.assertIn("    if: ${{ needs.changes.outputs.codetracer == 'true' }}\n", job)
        self.assertIn("    uses: ./.github/workflows/codetracer-mac-lock.yml\n", job)
        self.assertIn("    secrets: inherit\n", job)
        # Called with no inputs: it solves the pin and expects the solve to succeed.
        self.assertNotIn("    with:", job)
        self.assertNotIn("  # codetracer-mac-lock:", self.workflow)

    def test_a_solved_lock_passes(self):
        for outcome in ("confirmed", "produced"):
            with self.subTest(outcome):
                code, out = self.gate(self.needs(mac=("success", outcome)))
                self.assertEqual(code, 0, out)

    def test_every_other_outcome_fails_even_beside_a_successful_result(self):
        # The reusable workflow's result job fails on each of these; the gate
        # must not rely on that alone.
        for outcome in ("unsolvable", "failed-checks", "invalid-pin", "failed", "skipped",
                        "solved-unexpectedly", "unverified", "", None):
            for result in ("success", "failure"):
                with self.subTest(outcome=outcome, result=result):
                    code, out = self.gate(self.needs(mac=(result, outcome)))
                    self.assertEqual(code, 1, out)

    def test_a_failed_or_cancelled_job_fails_whatever_its_outcome(self):
        for result in ("failure", "cancelled"):
            with self.subTest(result):
                code, out = self.gate(self.needs(mac=(result, "confirmed")))
                self.assertEqual(code, 1, out)

    def test_a_skipped_lock_job_fails_a_codetracer_change(self):
        code, out = self.gate(self.needs(mac=("skipped", None)))
        self.assertEqual(code, 1, out)

    def test_a_codetracer_change_without_the_job_in_needs_fails(self):
        code, out = self.gate(self.needs(mac=None))
        self.assertEqual(code, 1, out)
        self.assertIn("not in needs", out)

    def test_an_unrelated_change_passes_with_the_lock_job_skipped(self):
        code, out = self.gate(self.needs(codetracer=False, mac=("skipped", None)))
        self.assertEqual(code, 0, out)

    def test_an_unrelated_change_does_not_accept_a_failed_lock_job(self):
        code, out = self.gate(self.needs(codetracer=False, mac=("failure", "failed")))
        self.assertEqual(code, 1, out)


if __name__ == "__main__":
    unittest.main()
