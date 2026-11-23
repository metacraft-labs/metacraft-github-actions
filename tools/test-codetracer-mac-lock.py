#!/usr/bin/env python3
"""Tests of tools/codetracer-mac-lock.py that run on any host.

Real git repositories over the file:// transport for `fetch`, real lock-file
fixtures in CodeTracer's format for `check`, and, for `solve`, the real
orchestration with a recording `repro` stand-in in place of the engine (the
engine itself only runs on the arm64 macOS runner). The stand-in goes through
the real git-auth/scoped-git-auth.sh credential path, with HOME pointed at a
scratch directory so nothing touches the caller's git configuration.

Run: python3 -I tools/test-codetracer-mac-lock.py
"""

import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent
TOOL = HERE / "codetracer-mac-lock.py"
PIN = HERE.parent / "pins" / "codetracer.json"

ENGINE = "b" * 40
CATALOG = "c" * 40
SHA_A = "1" * 40
SHA_B = "2" * 40


def dep(name, rev, self_entry=False):
    flag = 'self = "true", ' if self_entry else ""
    return (f'{{ name = "{name}", {flag}coord_kind = "vcs", '
            f'url = "https://github.com/metacraft-labs/{name}", ref = "agents", '
            f'revision = "{rev}", integrity = "git-sha1:{rev}", version = "", '
            f'visibility = "public", participation = "", depends = "", tags = "" }}')


def lock_text(plat, deps, packages="bash", digest="fnv1a64:0000000000000001", self_rev="9" * 40):
    entries = [dep("codetracer", self_rev, self_entry=True)]
    entries += [dep(name, rev) for name, rev in sorted(deps.items())]
    pkgs = ", ".join(
        f'{{ name = "{p}", version = "1.0.0", source = "{p}", selection = "selected" }}'
        for p in packages.split())
    return textwrap.dedent(f"""\
        schema = "reprobuild.solved-graph-lock.v3"

        [lock]
        platform = "{plat}"
        optimal = false
        inputs_digest = "{digest}"
        variants = []
        packages = [{pkgs}]
        deps = [{", ".join(entries)}]
        """)


DEPS = {"isonim": SHA_A, "reprobuild": ENGINE, "reprobuild-packages": CATALOG}

FLAKE_LOCK = {
    "nodes": {
        "root": {"inputs": {"reprobuild": "reprobuild", "reprobuild-packages": "reprobuild-packages"}},
        "reprobuild": {"locked": {"type": "github", "owner": "metacraft-labs",
                                  "repo": "reprobuild", "rev": ENGINE}},
        "reprobuild-packages": {"locked": {
            "type": "github", "owner": "metacraft-labs", "repo": "reprobuild-packages", "rev": CATALOG}},
    },
    "root": "root",
    "version": 7,
}

REPRO_NIM = textwrap.dedent("""\
    import repro_dsl_stdlib

    package codeTracer:
      defaultToolProvisioning "nix"

      uses:
        "bash >=4"
        "git >=2"
    """)


def run_tool(*argv, env=None, cwd=None):
    return subprocess.run([sys.executable, "-I", str(TOOL), *argv], capture_output=True,
                          text=True, env=env, cwd=cwd, check=False)


def git(*argv, cwd=None):
    env = dict(
        os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    return subprocess.run(["git", *argv], cwd=cwd, env=env, capture_output=True,
                          text=True, check=True).stdout.strip()


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="codetracer-mac-lock-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def checkout(self, name="ws/codetracer", native=None, canonical=None):
        base = pathlib.Path(name)
        self.write(base / "repro.lock", canonical or lock_text("amd64-linux", DEPS))
        self.write(base / "locks/arm64-macosx.lock", native or lock_text("arm64-macosx", DEPS))
        self.write(base / "flake.lock", json.dumps(FLAKE_LOCK))
        self.write(base / "repro.nim", REPRO_NIM)
        return self.root / base


class ResolveTests(Scratch):
    def pin(self, **overrides):
        pin = {
            "schema": 1, "tool": "codetracer", "owner": "metacraft-labs",
            "repo": "codetracer", "rev": SHA_A,
            "narHash": "sha256-" + "A" * 43 + "=", "kind": "dev-commit",
        }
        pin.update(overrides)
        return self.write("codetracer.json", json.dumps(pin))

    def test_the_committed_pin_resolves(self):
        res = run_tool("resolve", "--pin", str(PIN))
        self.assertEqual(res.returncode, 0, res.stderr)
        rev = json.loads(PIN.read_text())["rev"]
        self.assertIn(f"rev={rev}\n", res.stdout)
        self.assertIn("source=pin\n", res.stdout)

    def test_pin_revision_is_used_by_default(self):
        res = run_tool("resolve", "--pin", str(self.pin()))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn(f"rev={SHA_A}\nsource=pin\n", res.stdout)

    def test_explicit_revision_overrides_the_pin(self):
        res = run_tool("resolve", "--pin", str(self.pin()), "--rev", SHA_B)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn(f"rev={SHA_B}\nsource=input\n", res.stdout)
        self.assertIn(f"pinned-rev={SHA_A}\n", res.stdout)

    def test_malformed_explicit_revisions_are_refused(self):
        for bad in ("dev", "a3986b0de1", "a3986B0de1c215bcc9bd2bfa5c9619f0fa6bc5f3",
                    SHA_A + "0", f"{SHA_A[:-1]} ", SHA_A + "\n"):
            with self.subTest(rev=bad):
                res = run_tool("resolve", "--pin", str(self.pin()), "--rev", bad)
                self.assertEqual(res.returncode, 2, res.stdout)
                self.assertIn("not a full lowercase commit SHA", res.stderr)
                self.assertNotIn("rev=", res.stdout)

    def test_malformed_pins_are_refused(self):
        cases = {
            "branch rev": {"rev": "dev"},
            "other tool": {"tool": "reprobuild"},
            "schema 2": {"schema": 2},
            "owner with slash": {"owner": "metacraft-labs/x"},
        }
        for label, override in cases.items():
            with self.subTest(case=label):
                res = run_tool("resolve", "--pin", str(self.pin(**override)))
                self.assertEqual(res.returncode, 2, res.stdout)
        self.write("broken.json", "{")
        self.assertEqual(run_tool("resolve", "--pin", str(self.root / "broken.json")).returncode, 2)
        self.assertEqual(run_tool("resolve", "--pin", str(self.root / "absent.json")).returncode, 2)


class FetchTests(Scratch):
    def setUp(self):
        super().setUp()
        self.upstream = self.root / "upstream"
        git("init", "--quiet", "-b", "dev", str(self.upstream))
        (self.upstream / "repro.lock").write_text("x\n")
        git("add", "repro.lock", cwd=self.upstream)
        git("commit", "--quiet", "-m", "one", cwd=self.upstream)
        self.first = git("rev-parse", "HEAD", cwd=self.upstream)
        (self.upstream / "repro.lock").write_text("y\n")
        git("commit", "--quiet", "-am", "two", cwd=self.upstream)
        # GitHub serves any reachable commit by SHA; so does this fixture.
        git("config", "uploadpack.allowReachableSHA1InWant", "true", cwd=self.upstream)
        self.url = self.upstream.as_uri()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")

    def test_fetches_exactly_the_requested_revision(self):
        dest = self.root / "ws" / "codetracer"
        res = run_tool("fetch", "--rev", self.first, "--dest", str(dest), "--url", self.url, env=self.env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(git("rev-parse", "HEAD", cwd=dest), self.first)
        self.assertEqual((dest / "repro.lock").read_text(), "x\n")

    def test_a_revision_that_does_not_exist_is_exit_3(self):
        res = run_tool("fetch", "--rev", "d" * 40, "--dest", str(self.root / "d"), "--url", self.url, env=self.env)
        self.assertEqual(res.returncode, 3, res.stderr)
        self.assertIn("does not exist", res.stderr)

    def test_refuses_a_malformed_revision_and_a_non_empty_destination(self):
        res = run_tool("fetch", "--rev", "dev", "--dest", str(self.root / "d1"), "--url", self.url, env=self.env)
        self.assertEqual(res.returncode, 2)
        self.write("d2/keep", "x")
        res = run_tool("fetch", "--rev", self.first, "--dest", str(self.root / "d2"), "--url", self.url, env=self.env)
        self.assertEqual(res.returncode, 2)
        self.assertIn("not empty", res.stderr)


class InspectAndInjectTests(Scratch):
    def test_inspect_reports_codetracers_own_engine_and_catalog(self):
        res = run_tool("inspect", "--checkout", str(self.checkout()))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout, f"engine-rev={ENGINE}\ncatalog-rev={CATALOG}\n")

    def test_inspect_refuses_a_revision_without_the_darwin_lock(self):
        ct = self.checkout()
        (ct / "locks/arm64-macosx.lock").unlink()
        res = run_tool("inspect", "--checkout", str(ct))
        self.assertEqual(res.returncode, 2)
        self.assertIn("locks/arm64-macosx.lock", res.stderr)

    def test_inspect_refuses_a_follows_edge_for_the_engine(self):
        ct = self.checkout()
        flake = json.loads(json.dumps(FLAKE_LOCK))
        flake["nodes"]["root"]["inputs"]["reprobuild"] = ["nixos-modules", "reprobuild"]
        (ct / "flake.lock").write_text(json.dumps(flake))
        self.assertEqual(run_tool("inspect", "--checkout", str(ct)).returncode, 2)

    def test_inject_adds_an_unsatisfiable_use_inside_the_uses_block(self):
        ct = self.checkout()
        res = run_tool("inject-unsatisfiable", "--checkout", str(ct))
        self.assertEqual(res.returncode, 0, res.stderr)
        lines = (ct / "repro.nim").read_text().splitlines()
        at = lines.index("  uses:")
        self.assertIn('"bash <4"', lines[at + 1])
        self.assertEqual(lines[at + 2].strip(), '"bash >=4"')

    def test_inject_refuses_a_recipe_whose_uses_block_has_nothing_to_contradict(self):
        ct = self.checkout()
        (ct / "repro.nim").write_text(REPRO_NIM.replace('"bash >=4"', '"bash >=5"'))
        res = run_tool("inject-unsatisfiable", "--checkout", str(ct))
        self.assertEqual(res.returncode, 2)
        self.assertIn("would not contradict", res.stderr)
        self.assertNotIn('"bash <4"', (ct / "repro.nim").read_text())

    def test_inject_refuses_a_recipe_without_a_uses_block(self):
        ct = self.checkout()
        (ct / "repro.nim").write_text("package x:\n  discard\n")
        self.assertEqual(run_tool("inject-unsatisfiable", "--checkout", str(ct)).returncode, 2)


class CheckTests(Scratch):
    def check(self, produced, committed=None):
        ct = self.checkout(native=committed)
        produced_path = self.write("produced.lock", produced)
        return run_tool("check", "--checkout", str(ct), "--produced", str(produced_path),
                        "--committed", str(ct / "locks/arm64-macosx.lock"))

    def test_same_solve_with_a_new_self_entry_is_confirmed(self):
        res = self.check(lock_text("arm64-macosx", DEPS, self_rev="8" * 40))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("outcome=confirmed", res.stdout)

    def test_a_different_solve_is_produced_and_named(self):
        res = self.check(lock_text("arm64-macosx", DEPS, packages="bash clang"))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("outcome=produced", res.stdout)
        self.assertIn("packages", res.stdout)

    def test_a_drifted_committed_lock_is_produced_not_failed(self):
        # The state measured on CodeTracer dev and agents on 2026-11-23: the
        # committed darwin lock trails repro.lock. A fresh solve fixes it.
        stale = lock_text("arm64-macosx", dict(DEPS, isonim=SHA_B))
        res = self.check(lock_text("arm64-macosx", DEPS), committed=stale)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("outcome=produced", res.stdout)
        self.assertIn(f"isonim: {SHA_B} -> {SHA_A}", res.stdout)

    def test_a_solve_whose_pins_differ_from_repro_lock_fails(self):
        res = self.check(lock_text("arm64-macosx", dict(DEPS, isonim=SHA_B)))
        self.assertEqual(res.returncode, 1)
        self.assertIn("dependency isonim", res.stdout)

    def test_a_solve_for_another_platform_fails(self):
        res = self.check(lock_text("amd64-linux", DEPS))
        self.assertEqual(res.returncode, 1)
        self.assertIn("platform", res.stdout)

    def test_an_engine_pin_that_disagrees_with_flake_lock_fails(self):
        moved = dict(DEPS, reprobuild=SHA_B)
        ct = self.checkout(canonical=lock_text("amd64-linux", moved))
        produced = self.write("produced.lock", lock_text("arm64-macosx", moved))
        res = run_tool("check", "--checkout", str(ct), "--produced", str(produced))
        self.assertEqual(res.returncode, 1)
        self.assertIn("flake.lock", res.stdout)

    def test_a_solve_with_no_dependency_pins_fails(self):
        text = "\n".join(l for l in lock_text("arm64-macosx", DEPS).splitlines() if not l.startswith("deps"))
        res = self.check(text + "\n")
        self.assertEqual(res.returncode, 1)


STUB_REPRO = """\
#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$STUB_LOG"
case "$1" in
  --version) echo "repro stub"; echo "packages-root=${REPROBUILD_PACKAGES_ROOT:-}" >> "$STUB_LOG" ;;
  develop)
    [ -n "${GIT_CONFIG_GLOBAL:-}" ] && [ -f "$GIT_CONFIG_GLOBAL" ] || { echo "no private git config" >&2; exit 9; }
    if grep -q 'extraHeader' "$GIT_CONFIG_GLOBAL"; then echo "develop-auth=header" >> "$STUB_LOG"; fi
    echo "develop-config=$GIT_CONFIG_GLOBAL" >> "$STUB_LOG"
    case "$*" in
      *--only=*) ;;
      *)
        for n in ${STUB_PINNED:-}; do
          echo "repro develop --all: skipped $n — pinned by recipe at flake.nix:1: '$n' is not substituted by a bulk selection"
        done ;;
    esac
    [ -z "${STUB_ONLY_STATUS:-}" ] || case "$*" in *--only=*) exit "$STUB_ONLY_STATUS" ;; esac
    exit "${STUB_DEVELOP_STATUS:-0}" ;;
  lock)
    # The real solver's answer to contradictory ranges: exit 3, "solver UNSAT".
    # A floor alone is satisfiable (it grounds at the floor), so only a
    # contradiction is UNSAT here, as there.
    if grep -q '"bash <4"' repro.nim && grep -q '"bash >=4"' repro.nim; then
      if [ -n "${STUB_UNSAT_IN_EXTRACT:-}" ]; then
        # The shape measured on the hosted runner: the interface extraction
        # runs the solve, and the refresh reports that as exit 1.
        echo "repro lock refresh: failed to read inputs: could not read the solve of repro.nim" >&2
        echo "Error: unhandled exception: no satisfying assignment exists for the supplied variant + package registry [EUnsatisfiable]" >&2
        exit 1
      fi
      echo "repro lock refresh: solver UNSAT — cannot pin a lock: bash" >&2; exit 3
    fi
    [ -z "${STUB_SOLVE_STATUS:-}" ] || { echo "${STUB_SOLVE_TEXT:-generation failed}" >&2; exit "$STUB_SOLVE_STATUS"; }
    cp "$STUB_PRODUCED" locks/arm64-macosx.lock ;;
  *) exit 64 ;;
esac
"""


class SolveFixture(Scratch):
    def setUp(self):
        super().setUp()
        self.ct = self.checkout()
        self.out = self.root / "out"
        stub = self.write("bin/repro", STUB_REPRO)
        stub.chmod(0o755)
        self.stub = stub
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"),
                        RUNNER_TEMP=str(self.root), STUB_LOG=str(self.root / "stub.log"),
                        STUB_PRODUCED=str(self.write("produced.lock", lock_text("arm64-macosx", DEPS))))
        for key in ("GH_TOKEN", "GITHUB_STEP_SUMMARY", "GIT_CONFIG_COUNT"):
            self.env.pop(key, None)

    def solve(self, *extra, **env):
        return run_tool("solve", "--rev", SHA_A, "--checkout", str(self.ct), "--out", str(self.out),
                        "--repro", str(self.stub), "--any-host", *extra, env=dict(self.env, **env))

    def result(self):
        return json.loads((self.out / "result.json").read_text())

    def stub_log(self):
        return (self.root / "stub.log").read_text()


class SolveTests(SolveFixture):
    def test_confirmed_solve_runs_develop_then_refresh_with_the_scoped_credential(self):
        summary = self.root / "summary.md"
        res = self.solve(GH_TOKEN="ghs_fixture_not_a_credential", GITHUB_STEP_SUMMARY=str(summary))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["outcome"], "confirmed")
        log = self.stub_log()
        self.assertIn(f"develop --all --reset --into={self.ct.parent}", log)
        self.assertIn("lock refresh . --lock locks/arm64-macosx.lock --platform=arm64-macosx", log)
        self.assertLess(log.index("develop"), log.index("lock refresh"))
        self.assertIn("develop-auth=header", log)
        # The private credential file is gone once develop returns.
        config = [l for l in log.splitlines() if l.startswith("develop-config=")][0].split("=", 1)[1]
        self.assertFalse(pathlib.Path(config).exists())
        self.assertNotIn("ghs_fixture_not_a_credential", summary.read_text())
        self.assertTrue((self.out / "arm64-macosx.lock").is_file())
        self.assertTrue((self.out / "committed-arm64-macosx.lock").is_file())

    def test_recipe_pinned_siblings_skipped_by_develop_all_are_selected_explicitly(self):
        res = self.solve(STUB_PINNED="test-certificates-tools nim-shm-queue")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["recipe_pinned"], ["nim-shm-queue", "test-certificates-tools"])
        log = self.stub_log()
        only = f"develop --all --only=nim-shm-queue,test-certificates-tools --reset --into={self.ct.parent}"
        self.assertIn(only, log)
        self.assertLess(log.index(only), log.index("lock refresh"))

    def test_no_recipe_pinned_siblings_means_one_develop(self):
        res = self.solve()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["recipe_pinned"], [])
        self.assertNotIn("--only=", self.stub_log())

    def test_a_failure_to_place_the_recipe_pinned_siblings_fails_before_the_solve(self):
        res = self.solve(STUB_PINNED="nim-shm-queue", STUB_ONLY_STATUS="7")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["stage"], "develop")
        self.assertNotIn("lock refresh", self.stub_log())

    def test_a_different_solve_is_produced(self):
        produced = self.write("p2.lock", lock_text("arm64-macosx", DEPS, packages="bash clang"))
        res = self.solve(STUB_PRODUCED=str(produced))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["outcome"], "produced")

    def test_an_unsolvable_revision_fails(self):
        res = self.solve(STUB_SOLVE_STATUS="3", STUB_SOLVE_TEXT="repro lock refresh: solver UNSAT — x")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "unsolvable")
        self.assertEqual(self.result()["stage"], "solve")

    def test_a_refresh_that_fails_otherwise_fails_as_failed(self):
        res = self.solve(STUB_SOLVE_STATUS="4", STUB_SOLVE_TEXT="pin would move backward")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "failed")
        self.assertEqual(self.result()["refresh_exit"], 4)

    def test_a_solve_that_fails_its_checks_fails(self):
        bad = self.write("bad.lock", lock_text("arm64-macosx", dict(DEPS, isonim=SHA_B)))
        res = self.solve(STUB_PRODUCED=str(bad))
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "failed-checks")

    def test_negative_control_passes_only_when_the_solve_fails(self):
        res = self.solve("--expect", "fail", "--negative-control")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["outcome"], "unsolvable")
        self.assertIn('"bash <4"', (self.ct / "repro.nim").read_text())

    def test_negative_control_accepts_the_unsat_raised_by_interface_extraction(self):
        res = self.solve("--expect", "fail", "--negative-control", STUB_UNSAT_IN_EXTRACT="1")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.result()["outcome"], "unsolvable")
        self.assertEqual(self.result()["refresh_exit"], 1)

    def test_a_floor_alone_is_not_a_negative_control(self):
        # What the first version of this tool injected. The solver grounds a
        # floor and solves, so expecting failure of it must fail the run.
        (self.ct / "repro.nim").write_text(
            REPRO_NIM.replace('  uses:\n', '  uses:\n    "bash >=99999"\n'))
        res = self.solve("--expect", "fail")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "solved-unexpectedly")

    def test_a_failure_that_is_not_unsat_never_counts_as_the_expected_failure(self):
        cases = (
            ("1", "generation failed: network"),
            ("5", "incomplete solve"),
            ("3", "exit 3 without the solver's words"),
        )
        for status, text in cases:
            with self.subTest(status=status):
                ct = self.checkout(name=f"ws{status}{len(text)}/codetracer")
                res = run_tool(
                    "solve", "--rev", SHA_A, "--checkout", str(ct), "--out", str(self.out),
                    "--repro", str(self.stub), "--any-host", "--expect", "fail",
                    env=dict(self.env, STUB_SOLVE_STATUS=status, STUB_SOLVE_TEXT=text))
                self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
                self.assertEqual(self.result()["outcome"], "failed")

    def test_expecting_failure_of_a_solvable_revision_fails(self):
        res = self.solve("--expect", "fail")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "solved-unexpectedly")

    def test_a_provisioning_failure_never_counts_as_the_expected_failure(self):
        res = self.solve("--expect", "fail", "--negative-control", STUB_DEVELOP_STATUS="7")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["stage"], "develop")
        self.assertNotIn("lock refresh", self.stub_log())

    def test_a_missing_engine_fails_cleanly(self):
        res = run_tool(
            "solve", "--rev", SHA_A, "--checkout", str(self.ct), "--out", str(self.out),
            "--repro", str(self.root / "absent"), "--any-host", env=self.env)
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.result()["outcome"], "failed")

    @unittest.skipIf(
        platform.system() == "Darwin" and platform.machine() == "arm64",
        "the host check passes on an arm64 Mac")
    def test_refuses_to_solve_on_another_host(self):
        res = run_tool(
            "solve", "--rev", SHA_A, "--checkout", str(self.ct), "--out", str(self.out),
            "--repro", str(self.stub), env=self.env)
        self.assertEqual(res.returncode, 2)
        self.assertIn("arm64 macOS", res.stderr)
        self.assertFalse((self.root / "stub.log").exists())


STUB_NIX = """\
#!/usr/bin/env bash
# Records each expression; `build` answers with a fake store path holding the
# executables the tool looks for, `eval --raw` with a directory.
set -eu
expr=""
prev=""
for a in "$@"; do [ "$prev" = --expr ] && expr="$a"; prev="$a"; done
printf '%s %s\\n' "$3" "$expr" >> "$STUB_NIX_LOG"
[ -z "${STUB_NIX_FAIL:-}" ] || { echo "error: stub build failure" >&2; exit 1; }
out="$STUB_STORE/$(printf '%s' "$expr" | cksum | cut -d' ' -f1)"
mkdir -p "$out/bin"
case "$3" in
  build)
    for exe in repro clang bash; do
      printf '#!/usr/bin/env bash\\nexec "$STUB_REPRO" "$@"\\n' > "$out/bin/$exe"
      chmod +x "$out/bin/$exe"
    done
    echo "$out" ;;
  eval) printf '%s' "$out" ;;
  *) exit 64 ;;
esac
"""


class EngineTests(SolveFixture):
    def setUp(self):
        super().setUp()
        nix = self.write("nixbin/nix", STUB_NIX)
        nix.chmod(0o755)
        (self.root / "store").mkdir()
        self.env.update(PATH=f"{nix.parent}:{os.environ['PATH']}", STUB_STORE=str(self.root / "store"),
                        STUB_NIX_LOG=str(self.root / "nix.log"), STUB_REPRO=str(self.stub))

    def test_engine_builds_codetracers_own_reprobuild_input_and_solve_uses_it(self):
        engine_file = self.root / "engine.json"
        res = run_tool("engine", "--rev", SHA_A, "--out", str(engine_file), env=self.env)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        nix_log = (self.root / "nix.log").read_text()
        flake = f'(builtins.getFlake "github:metacraft-labs/codetracer/{SHA_A}")'
        self.assertIn(f"build {flake}.inputs.reprobuild.packages.aarch64-darwin.reprobuild", nix_log)
        self.assertIn(f"eval {flake}.inputs.reprobuild-packages.outPath", nix_log)
        engine = json.loads(engine_file.read_text())
        self.assertTrue(engine["repro"].endswith("/bin/repro"))
        self.assertEqual(
            sorted(engine["env"]),
            ["REPROBUILD_PACKAGES_ROOT", "REPRO_BOOTSTRAP_CC", "REPRO_FOREIGN_ENV_BASH"])
        self.assertTrue(engine["env"]["REPRO_BOOTSTRAP_CC"].endswith("/bin/clang"))
        res = run_tool(
            "solve", "--rev", SHA_A, "--checkout", str(self.ct), "--out", str(self.out),
            "--engine-file", str(engine_file), "--any-host", env=self.env)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn(f"packages-root={engine['env']['REPROBUILD_PACKAGES_ROOT']}\n", self.stub_log())
        self.assertEqual(self.result()["outcome"], "confirmed")

    def test_an_engine_that_does_not_build_fails(self):
        res = run_tool(
            "engine", "--rev", SHA_A, "--out", str(self.root / "e.json"),
            env=dict(self.env, STUB_NIX_FAIL="1"))
        self.assertEqual(res.returncode, 1)
        self.assertIn("stub build failure", res.stderr)
        self.assertFalse((self.root / "e.json").exists())

    def test_engine_refuses_a_malformed_revision(self):
        res = run_tool("engine", "--rev", "dev", "--out", str(self.root / "e.json"), env=self.env)
        self.assertEqual(res.returncode, 2)


if __name__ == "__main__":
    unittest.main()
