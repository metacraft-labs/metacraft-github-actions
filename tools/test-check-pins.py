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
        # Each mutation is applied inside the `remote` job only: other jobs
        # mint tokens of their own (the Windows pin prerelease build narrows
        # its token to contents:read too), and the lines must be unique
        # where they are changed, not across the workflow.
        remote = workflow_job(workflow, "remote")
        for why, (old, new) in widened.items():
            with self.subTest(why):
                self.assertEqual(remote.count(old), 1, old)
                mutated = workflow.replace(remote, remote.replace(old, new))
                self.assertNotEqual(owner_token_narrowing_defects(mutated), [], why)

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


class TokensOutliveLongBuilds(unittest.TestCase):
    """An installation token expires one hour after it is minted. In the jobs
    whose build can take longer, every step after the build must use the token
    minted after it, `steps.token_after_build`, and never the one minted
    before. Run 45687602690 failed because a step used the earlier token after
    a 65-minute build."""

    # job -> (the long build step's name, the fresh token's mint step's name)
    JOBS = {
        "reprobuild-package": (
            "Section 0: the pinned package builds",
            "Mint a fresh read token for the steps after the build",
        ),
        "windows-pin-release-build": (
            "Build the pinned commit from source",
            "Mint a fresh read token for the steps after the build",
        ),
    }

    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def test_steps_after_the_build_use_the_token_minted_after_it(self):
        for job, (build, mint) in self.JOBS.items():
            with self.subTest(job=job):
                text = workflow_job(self.workflow, job)
                # A name with a colon is quoted in the YAML, so match the name
                # itself rather than the whole `- name:` line.
                build_at = text.index(build)
                mint_at = text.index(mint)
                self.assertLess(
                    build_at, mint_at, f"{job}: the fresh token is minted before the build")
                after = text[mint_at:]
                self.assertNotIn(
                    "steps.token.outputs.token", after,
                    f"{job}: a step after the build uses the token minted before it")
                self.assertIn(
                    "steps.token_after_build.outputs.token", after,
                    f"{job}: no step uses the fresh token")


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


def changes_script(workflow):
    """The shell the `changes` job's diff step runs, as pins.yml holds it."""
    step = workflow_step(workflow, "Which parts of the gate this change needs")
    body = step[step.index("        run: |\n") + len("        run: |\n"):]
    return textwrap.dedent(body)


# A stand-in for `gh api` on the two endpoints the CodeTracer proof reads: it
# answers from the JSON files a case writes into $FAKE_GH, and fails like gh
# does for any other request. Every call is logged.
FAKE_GH = r"""#!/usr/bin/env python3
import os, re, sys
d = os.environ["FAKE_GH"]
with open(os.path.join(d, "calls"), "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
url = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "api" else ""
m = re.match(r"repos/[^/]+/[^/]+/actions/workflows/pins\.yml/runs\?.*head_sha=([0-9a-f]{40})", url)
n = re.match(r"repos/[^/]+/[^/]+/actions/runs/(\d+)/jobs", url)
name = f"runs-{m.group(1)}.json" if m else f"jobs-{n.group(1)}.json" if n else None
if m and not all(q in url for q in ("event=pull_request", "status=success")):
    name = None
path = os.path.join(d, name) if name else None
if not path or not os.path.exists(path):
    print("gh: HTTP 404", file=sys.stderr); sys.exit(1)
sys.stdout.write(open(path).read())
"""


class ChangesJob(unittest.TestCase):
    """The `changes` job's shell, run as pins.yml holds it, on real Git
    histories: which parts of the gate each event and change needs, above all
    when the hosted Mac (`codetracer` flag) runs."""

    @classmethod
    def setUpClass(cls):
        cls.script = changes_script(WORKFLOW.read_text())

    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="pins-changes-")
        self.addCleanup(shutil.rmtree, tmp)
        self.tmp = pathlib.Path(tmp)
        self.repo = self.tmp / "repo"
        self.gh = self.tmp / "gh"
        for d in (self.repo, self.gh, self.tmp / "bin", self.tmp / "runner"):
            d.mkdir()
        (self.tmp / "bin" / "gh").write_text(FAKE_GH)
        (self.tmp / "bin" / "gh").chmod(0o755)
        (self.tmp / "script.sh").write_text(self.script)
        self.git("init", "-q", "-b", "agents")
        self.base = self.commit({"pins/codetracer.json": "v1\n", "README.md": "readme\n"}, "base")

    def git(self, *args):
        env = dict(
            os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        return subprocess.run(["git", "-C", str(self.repo), "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True, env=env).stdout.strip()

    def commit(self, files, message):
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            self.git("add", name)
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def branch(self, files):
        """A branch off base carrying `files`, merged into base with a merge
        commit, as a pull request merges (and as its test merge looks):
        (branch head, merge commit)."""
        self.git("checkout", "-q", "-b", "feature", self.base)
        head = self.commit(files, "feature")
        self.git("checkout", "-q", "agents")
        self.git("merge", "-q", "--no-ff", "-m", "merge", head)
        return head, self.git("rev-parse", "HEAD")

    def prove(self, sha, jobs=None, run=7):
        """Record a successful pull_request run of pins.yml on `sha`."""
        jobs = {"codetracer-mac-lock / result": "success", "pins-gate": "success"} \
            if jobs is None else jobs
        (self.gh / f"runs-{sha}.json").write_text(json.dumps({"workflow_runs": [{"id": run}]}))
        (self.gh / f"jobs-{run}.json").write_text(json.dumps(
            {"jobs": [{"name": k, "conclusion": v} for k, v in jobs.items()]}))

    def run_changes(self, event, base="", dispatch=""):
        out = self.tmp / "runner" / "output"
        out.write_text("")
        env = dict(
            os.environ, EVENT=event, BASE=base, DISPATCH_CODETRACER=dispatch,
            GH_TOKEN="unused", GITHUB_REPOSITORY="metacraft-labs/metacraft-github-actions",
            GITHUB_OUTPUT=str(out), RUNNER_TEMP=str(self.tmp / "runner"),
            FAKE_GH=str(self.gh), PATH=f"{self.tmp / 'bin'}{os.pathsep}{os.environ['PATH']}")
        # Actions runs a `run:` step with no `shell:` as `bash -e {0}`.
        done = subprocess.run(["bash", "--noprofile", "--norc", "-e", str(self.tmp / "script.sh")],
                              cwd=self.repo, env=env, capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        flags = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.log = done.stdout + done.stderr
        return {k: flags[k] for k in ("pins", "reprobuild", "codetracer")}

    def gh_calls(self):
        calls = self.gh / "calls"
        return calls.read_text().splitlines() if calls.exists() else []

    NONE = {"pins": "false", "reprobuild": "false", "codetracer": "false"}
    CT = {"pins": "true", "reprobuild": "false", "codetracer": "true"}
    CT_PROVEN = {"pins": "true", "reprobuild": "false", "codetracer": "false"}
    EVERYTHING_BUT_CT = {"pins": "true", "reprobuild": "true", "codetracer": "false"}
    EVERYTHING = {"pins": "true", "reprobuild": "true", "codetracer": "true"}

    def test_a_pull_request_runs_the_mac_for_a_codetracer_change_only(self):
        self.branch({"pins/codetracer.json": "v2\n"})
        # The test merge's second parent is the pull request itself, so the
        # push-only proof must not apply here even though one exists.
        self.prove(self.git("rev-parse", "HEAD^2"))
        self.assertEqual(self.run_changes("pull_request", self.base), self.CT)
        self.assertEqual(self.gh_calls(), [])

    def test_each_codetracer_file_is_a_codetracer_change(self):
        names = (
            "pins/codetracer.json", ".github/workflows/codetracer-mac-lock.yml",
            "tools/codetracer-mac-lock.py")
        for name in names:
            with self.subTest(name):
                self.commit({name: f"changed {name}\n"}, name)
                flags = self.run_changes("pull_request", self.git("rev-parse", "HEAD^"))
                self.assertEqual(flags["codetracer"], "true")

    def test_an_unrelated_pull_request_runs_nothing(self):
        self.branch({"README.md": "changed\n"})
        self.assertEqual(self.run_changes("pull_request", self.base), self.NONE)

    def test_a_reprobuild_pin_change_does_not_run_the_mac(self):
        self.branch({"pins/reprobuild.json": "{}\n"})
        self.assertEqual(
            self.run_changes("pull_request", self.base),
            {"pins": "true", "reprobuild": "true", "codetracer": "false"})

    def test_a_merge_push_proven_on_its_pull_request_skips_the_mac(self):
        head, _ = self.branch({"pins/codetracer.json": "v2\n"})
        self.prove(head)
        self.assertEqual(self.run_changes("push", self.base), self.CT_PROVEN)
        self.assertIn(f"proven by pull request run 7 on {head}", self.log)

    def test_a_merge_push_without_a_proof_runs_the_mac(self):
        # Positive controls for the skip above: each missing piece of the
        # proof runs the Mac.
        cases = {
            "no pull request run": None,
            "the lock job did not succeed": {
                "codetracer-mac-lock / result": "skipped", "pins-gate": "success"},
            "the lock job is absent": {"pins-gate": "success"},
            "the gate failed": {
                "codetracer-mac-lock / result": "success", "pins-gate": "failure"},
        }
        head, _ = self.branch({"pins/codetracer.json": "v2\n"})
        for why, jobs in cases.items():
            with self.subTest(why):
                for f in self.gh.iterdir():
                    f.unlink()
                if jobs is not None:
                    self.prove(head, jobs)
                self.assertEqual(self.run_changes("push", self.base), self.CT)
                self.assertNotEqual(self.gh_calls(), [])

    def test_a_merge_push_whose_files_differ_from_the_proven_branch_runs_the_mac(self):
        # The merge itself changed the pin (a conflict resolution, an amended
        # merge): the merged branch's proof is not about these bytes.
        head, _ = self.branch({"pins/codetracer.json": "v2\n"})
        self.prove(head)
        (self.repo / "pins/codetracer.json").write_text("v3\n")
        self.git("commit", "-q", "--amend", "-a", "--no-edit")
        self.assertEqual(self.run_changes("push", self.base), self.CT)
        self.assertEqual(self.gh_calls(), [])

    def test_a_direct_push_runs_the_mac(self):
        self.commit({"pins/codetracer.json": "v2\n"}, "direct")
        self.assertEqual(self.run_changes("push", self.base), self.CT)

    def test_an_unrelated_push_runs_nothing_and_asks_no_api(self):
        self.branch({"README.md": "changed\n"})
        self.assertEqual(self.run_changes("push", self.base), self.NONE)
        self.assertEqual(self.gh_calls(), [])

    def test_a_push_with_no_before_runs_the_mac_unless_proven(self):
        self.commit({"pins/codetracer.json": "v2\n"}, "direct")
        zero = "0" * 40
        self.assertEqual(self.run_changes("push", zero), self.EVERYTHING)
        self.git("reset", "-q", "--keep", self.base)
        head, _ = self.branch({"pins/codetracer.json": "v2\n"})
        self.prove(head)
        self.assertEqual(self.run_changes("push", zero), self.EVERYTHING_BUT_CT)

    def test_a_diff_that_fails_runs_everything(self):
        self.commit({"README.md": "changed\n"}, "readme")
        self.assertEqual(self.run_changes("pull_request", "f" * 40), self.EVERYTHING)

    def test_the_schedule_never_runs_the_mac(self):
        self.commit({"pins/codetracer.json": "v2\n"}, "direct")
        self.assertEqual(self.run_changes("schedule"), self.EVERYTHING_BUT_CT)

    def test_a_dispatch_runs_the_mac_only_when_its_input_asks(self):
        self.assertEqual(self.run_changes("workflow_dispatch", dispatch=""), self.EVERYTHING_BUT_CT)
        self.assertEqual(
            self.run_changes("workflow_dispatch", dispatch="false"), self.EVERYTHING_BUT_CT)
        self.assertEqual(self.run_changes("workflow_dispatch", dispatch="true"), self.EVERYTHING)

    def test_the_dispatch_input_and_the_api_permission_are_declared(self):
        workflow = WORKFLOW.read_text()
        trigger = workflow[workflow.index("on:\n"):workflow.index("\npermissions:\n")]
        self.assertIn("      codetracer-mac-lock:\n", trigger)
        self.assertIn("        type: boolean\n        default: false\n", trigger)
        job = workflow_job(workflow, "changes")
        self.assertIn("    permissions:\n      contents: read\n", job)
        self.assertIn("      actions: read\n", job)
        self.assertIn("          DISPATCH_CODETRACER: ${{ inputs.codetracer-mac-lock }}\n", job)



def step_script(workflow, name):
    """The shell a pins.yml step called `name` runs, as the workflow holds it."""
    step = workflow_step(workflow, name)
    body = step[step.index("        run: |\n") + len("        run: |\n"):]
    return textwrap.dedent(body)


# A stand-in for the few `nix` commands the reprobuild-cache job runs. It
# answers from $FAKE_NIX: `system` (the runner's system), `ref` (the flake
# reference `pins` evaluates to), `cached` (the store paths the cache holds,
# one per line). Every call is logged to `calls`, with the XDG_CONFIG_HOME it
# saw (nix reads its user nix.conf from there).
FAKE_NIX = r"""#!/usr/bin/env python3
import os, sys
d = os.environ["FAKE_NIX"]
args = sys.argv[1:]
with open(os.path.join(d, "calls"), "a") as log:
    log.write(" ".join(args) + " XDG_CONFIG_HOME=" + os.environ.get("XDG_CONFIG_HOME", "") + "\n")
read = lambda name: open(os.path.join(d, name)).read().strip()
if args[:2] == ["eval", "--raw"]:
    if args[2:] == ["--impure", "--expr", "builtins.currentSystem"]:
        print(read("system"), end="")
    elif args[2:] == ["--no-write-lock-file", ".#pins.reprobuild.flakeRef"]:
        print(read("ref"), end="")
    elif len(args) == 3 and args[2].endswith(".outPath"):
        attr = args[2].split("#packages.", 1)[1].split(".")[1]
        print(f"/nix/store/{'a' * 32}-{attr}", end="")
    else:
        sys.exit(f"fake nix: unexpected eval {args}")
elif args[:2] == ["path-info", "--store"] and len(args) == 4:
    cached = read("cached").split() if os.path.exists(os.path.join(d, "cached")) else []
    if args[3] not in cached:
        print(f"error: path '{args[3]}' is not valid", file=sys.stderr)
        sys.exit(1)
    print(args[3])
elif args[:1] == ["build"] and args[-1] == "nixpkgs#attic-client":
    print(os.path.join(d, "attic-client"))
else:
    sys.exit(f"fake nix: unexpected {args}")
"""

# A stand-in attic: logs each call with its XDG_CONFIG_HOME, and `login`
# writes the token where the real client does, $XDG_CONFIG_HOME/attic/config.toml.
FAKE_ATTIC = r"""#!/usr/bin/env python3
import os, sys
config = os.environ.get("XDG_CONFIG_HOME", "")
with open(os.path.join(os.environ["FAKE_NIX"], "attic-calls"), "a") as log:
    log.write(" ".join(sys.argv[1:]) + " XDG_CONFIG_HOME=" + config + "\n")
if sys.argv[1:2] == ["login"]:
    os.makedirs(os.path.join(config, "attic"), exist_ok=True)
    with open(os.path.join(config, "attic", "config.toml"), "w") as f:
        f.write("token = " + repr(sys.argv[-1]) + "\n")
"""


class ReprobuildCacheJob(unittest.TestCase):
    """The `reprobuild-cache` job publishes the pinned outputs to the
    organisation's Attic cache from runners that reach it. The hosted
    `reprobuild-package` job used to push instead; cache.metacraft-labs.com is
    a NetBird overlay address hosted runners cannot reach, so every push timed
    out (runs 45667796580, 45879841961) and, being continue-on-error, failed
    nothing. Its steps' shell runs here as written, against a stand-in nix."""

    PLAN = "Which pinned outputs the cache lacks"
    PUSH = "Push the missing outputs to the organisation cache"
    VERIFY = "The cache holds every pinned output"

    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()
        # workflow_job keeps the comment block that heads the next job.
        job = workflow_job(cls.workflow, "reprobuild-cache")
        cls.job = job[:job.find("\n  # ")] if "\n  # " in job else job
        cls.rev = json.loads((ROOT / "pins" / "reprobuild.json").read_text())["rev"]

    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="pins-cache-")
        self.addCleanup(shutil.rmtree, tmp)
        self.tmp = pathlib.Path(tmp)
        self.nix = self.tmp / "nix-state"
        for d in (self.nix, self.tmp / "bin", self.tmp / "runner", self.nix / "attic-client" / "bin"):
            d.mkdir(parents=True)
        fakes = (
            (self.tmp / "bin" / "nix", FAKE_NIX),
            (self.nix / "attic-client" / "bin" / "attic", FAKE_ATTIC),
        )
        for path, text in fakes:
            path.write_text(text)
            path.chmod(0o755)
        (self.nix / "system").write_text("x86_64-linux\n")
        (self.nix / "ref").write_text(
            f"github:metacraft-labs/reprobuild/{self.rev}?narHash=sha256-x\n")

    @staticmethod
    def out(attr):
        return f"/nix/store/{'a' * 32}-{attr}"

    def cache(self, *attrs):
        (self.nix / "cached").write_text("".join(self.out(a) + "\n" for a in attrs))

    def run_step(self, name, **env):
        script = self.tmp / "step.sh"
        script.write_text(step_script(self.workflow, name))
        output, summary = self.tmp / "runner" / "output", self.tmp / "runner" / "summary"
        output.write_text("")
        env = dict(
            os.environ, FAKE_NIX=str(self.nix), GITHUB_OUTPUT=str(output),
            GITHUB_STEP_SUMMARY=str(summary), RUNNER_TEMP=str(self.tmp / "runner"),
            ATTIC_SUBSTITUTER="https://cache.example/c",
            PATH=f"{self.tmp / 'bin'}{os.pathsep}{os.environ['PATH']}", **env)
        done = subprocess.run(["bash", "--noprofile", "--norc", "-e", str(script)],
                              cwd=ROOT, env=env, capture_output=True, text=True, check=False)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return done.returncode, done.stdout + done.stderr, outputs

    def plan(self, attrs="reprobuild repro-binary-cache", system="x86_64-linux"):
        return self.run_step(self.PLAN, SYSTEM=system, ATTRS=attrs)

    # -- the plan ----------------------------------------------------------

    def test_nothing_is_missing_when_the_cache_holds_every_output(self):
        self.cache("reprobuild", "repro-binary-cache")
        code, log, outputs = self.plan()
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["missing"], "")
        self.assertTrue(outputs["ref"].startswith(f"github:metacraft-labs/reprobuild/{self.rev}?"))

    def test_only_the_outputs_the_cache_lacks_are_missing(self):
        self.cache("reprobuild")
        code, log, outputs = self.plan()
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["missing"], "repro-binary-cache")
        self.cache()
        code, log, outputs = self.plan()
        self.assertEqual(outputs["missing"], "reprobuild repro-binary-cache")
        planned = (self.tmp / "runner" / "pin-cache-outs").read_text().split("\n")
        self.assertEqual(planned[:2], [
            f"reprobuild {self.out('reprobuild')}",
            f"repro-binary-cache {self.out('repro-binary-cache')}",
        ])

    def test_a_leg_on_the_wrong_system_fails(self):
        code, log, _ = self.plan(system="aarch64-darwin")
        self.assertEqual(code, 1, log)
        self.assertIn("this leg publishes aarch64-darwin but its runner is x86_64-linux", log)

    def test_a_flake_reference_that_is_not_the_pinned_rev_fails(self):
        (self.nix / "ref").write_text("github:metacraft-labs/reprobuild/" + "0" * 40 + "?narHash=x\n")
        code, log, _ = self.plan()
        self.assertEqual(code, 1, log)
        self.assertIn("unexpected flakeRef", log)

    # -- the push ----------------------------------------------------------

    def test_only_the_missing_outputs_are_pushed_and_attic_config_stays_in_the_job(self):
        self.cache("reprobuild")
        self.assertEqual(self.plan()[0], 0)
        code, log, _ = self.run_step(
            self.PUSH, MISSING="repro-binary-cache", ATTIC_TOKEN="t0ken",
            ATTIC_CACHE="the-cache", ATTIC_ENDPOINT="https://cache.example/")
        self.assertEqual(code, 0, log)
        calls = (self.nix / "attic-calls").read_text().splitlines()
        config = f"XDG_CONFIG_HOME={self.tmp / 'runner' / 'attic-config'}"
        self.assertEqual(calls, [
            f"login --set-default pins https://cache.example/ t0ken {config}",
            f"push the-cache {self.out('repro-binary-cache')} {config}",
        ])
        # The token does not outlive the step on a persistent runner.
        self.assertFalse((self.tmp / "runner" / "attic-config").exists())
        # nix keeps the user nix.conf setup-nix wrote: only attic is pointed
        # at the job's attic configuration.
        calls = (self.nix / "calls").read_text().splitlines()
        nix_build = [c for c in calls if c.startswith("build ")]
        self.assertEqual(len(nix_build), 1, nix_build)
        self.assertNotIn("attic-config", nix_build[0])

    def test_a_failed_push_still_removes_the_attic_configuration(self):
        (self.nix / "attic-client" / "bin" / "attic").write_text(
            FAKE_ATTIC + 'if sys.argv[1:2] == ["push"]:\n    sys.exit(3)\n')
        self.cache("reprobuild")
        self.assertEqual(self.plan()[0], 0)
        code, log, _ = self.run_step(
            self.PUSH, MISSING="repro-binary-cache", ATTIC_TOKEN="t0ken",
            ATTIC_CACHE="the-cache", ATTIC_ENDPOINT="https://cache.example/")
        self.assertEqual(code, 3, log)
        self.assertFalse((self.tmp / "runner" / "attic-config").exists())

    # -- the verification --------------------------------------------------

    def test_the_job_passes_only_when_the_cache_holds_every_planned_output(self):
        self.cache()
        self.assertEqual(self.plan()[0], 0)
        code, log, _ = self.run_step(self.VERIFY, SYSTEM="x86_64-linux")
        self.assertEqual(code, 1, log)
        self.assertIn("does not hold reprobuild", log)
        self.cache("reprobuild")
        code, log, _ = self.run_step(self.VERIFY, SYSTEM="x86_64-linux")
        self.assertEqual(code, 1, log)
        self.assertIn("does not hold repro-binary-cache", log)
        self.cache("reprobuild", "repro-binary-cache")
        code, log, _ = self.run_step(self.VERIFY, SYSTEM="x86_64-linux")
        self.assertEqual(code, 0, log)
        summary = (self.tmp / "runner" / "summary").read_text()
        self.assertIn(self.out("repro-binary-cache"), summary)

    def test_an_empty_plan_fails_the_verification(self):
        code, log, _ = self.run_step(self.VERIFY, SYSTEM="x86_64-linux")
        self.assertEqual(code, 1, log)
        self.assertIn("no pinned outputs were planned", log)

    # -- the job's shape ---------------------------------------------------

    def test_it_runs_after_a_landed_reprobuild_change_never_on_a_pull_request(self):
        self.assertIn(
            "    if: ${{ github.event_name != 'pull_request' && (github.ref == 'refs/heads/agents'"
            " || github.ref == 'refs/heads/dev') && needs.changes.outputs.reprobuild == 'true' }}\n",
            self.job)
        self.assertIn("    needs: [changes, local]\n", self.job)

    def test_each_leg_runs_on_a_self_hosted_runner_and_publishes_what_consumers_use(self):
        self.assertIn("    runs-on: ${{ matrix.runner }}\n", self.job)
        legs = {
            "x86_64-linux": ("[self-hosted, linux, x64]", "reprobuild repro-binary-cache"),
            "aarch64-darwin": ("[self-hosted, macos, arm64]", "reprobuild"),
        }
        for system, (runner, attrs) in legs.items():
            with self.subTest(system):
                self.assertIn(
                    f"          - system: {system}\n            runner: {runner}\n"
                    f"            attrs: {attrs}\n", self.job)
        for hosted in ("ubuntu-", "macos-1", "windows-20"):
            self.assertNotIn(hosted, self.job)

    def test_a_failure_is_visible_and_the_gate_does_not_wait_for_it(self):
        self.assertNotIn("continue-on-error:", self.job)
        gate = workflow_job(self.workflow, "pins-gate")
        self.assertNotIn("reprobuild-cache", gate)
        self.assertNotIn("reprobuild-cache", gate_script(self.workflow))

    def test_the_build_is_memory_bounded(self):
        build = step_script(self.workflow, "Build or substitute the missing outputs")
        self.assertIn("nix build --no-link --print-out-paths --max-jobs 1 --cores 4 ", build)

    def test_the_cache_is_read_with_a_failing_preflight_and_no_watch_store(self):
        self.assertIn("          substituter-preflight: fail\n", self.job)
        self.assertIn("          attic-token: ${{ secrets.ATTIC_TOKEN }}\n", self.job)
        self.assertNotIn("attic-cache:", self.job)

    def test_no_hosted_job_pushes_to_the_cache(self):
        package = workflow_job(self.workflow, "reprobuild-package")
        for word in ("attic push", "ATTIC_TOKEN", "continue-on-error:"):
            self.assertNotIn(word, package)


if __name__ == "__main__":
    unittest.main()
