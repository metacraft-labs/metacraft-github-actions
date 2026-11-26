"""check-judged-siblings.py derives the judged siblings from the source and
fails on any drift from reveal-sibling-pin-ancestry.sh's JUDGED_SIBLINGS.

Property protected: a pin bump that brings an engine judging a sibling the
step does not deepen -- or that moves the judgement somewhere this check
cannot read -- fails the `pins` workflow, instead of a consumer's CI after the
bump lands.

The fixture is a reduced Reprobuild source tree with the shape of reprobuild
37a109c4 (`bootstrapSiblingPackagePathFlagsFor`'s `specs`, `resolveRunquotaRoot`,
the two engine judges, and `config.nims`'s io-mon block and
`addSiblingFirstPackagePath` calls), not a mock of anything the check calls:
the check reads files, and these are files. It is reduced because the real
tree is 2,000 Nim files fetched over the network; the `pins` workflow runs the
check against the real pinned tree (`--fetch`) as well. The step script
compared is the real one in this repository.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
CHECK = HERE / 'check-judged-siblings.py'
ENGINE = 'libs/repro_interface_artifacts/src/repro_interface_artifacts.nim'

ENGINE_TEXT = '''\
## `observeSiblingCheckout` and `chooseSiblingSource(policy, obs)` in a doc comment are no calls.
proc observeSiblingCheckout*(checkout, pin: string): SiblingObservation =
  discard

proc staleSiblingRoot(sdkRoot: string): string =
  discard

proc resolveSiblingFirstPackagePath*(sdkRoot, envName: string;
    candidates: openArray[string]): string =
  let obs = observeSiblingCheckout(checkout, pin)
  let choice = chooseSiblingSource(policy, obs)

proc pinCheckedSiblingRoot(sdkRoot, envName, resolved: string): string =
  let choice = chooseSiblingSource(policy,
    observeSiblingCheckout(checkout, pin))

proc resolveCtTestRunnerAdapterPath(anchorRoot: string): string =
  let candidate = anchorRoot.parentDir / "reprobuild-ct-test-runner" /
    "libs" / "ct_test_runner_adapter" / "src"

proc resolveRunquotaRoot(anchorRoot, consumerParent: string): string =
  let marker = "libs" / "runquota_core" / "src" / "runquota_core.nim"
  for candidate in [explicitSourceEnv("RUNQUOTA_SRC"),
                    anchorRoot.parentDir / "runquota",
                    consumerParent / "runquota",
                    getEnv("RUNQUOTA_SRC")]:
    discard

proc bootstrapSiblingPackagePathFlagsFor*(reprobuildRoot: string;
    consumerParent: string): SiblingPackagePaths =
  let specs: seq[SiblingSpec] = @[
    ("REPRO_TEST_ADAPTERS_SRC", anchored([
      ".." / "reprobuild-test-adapters" / "src",
    ]), "repro_test_adapters" / "test_runner.nim"),
    ("FASTSTREAMS_SRC", anchored([
      "libs" / "nim-faststreams" / "src",
      ".." / "codetracer" / "libs" / "nim-faststreams",
      ".." / "nim-faststreams",
    ]), "faststreams" / "inputs.nim"),
    ("NIM_STEW_SRC", anchored([".." / "nim-stew"]), "stew" / "objects.nim"),
    ("NIM_SERIALIZATION_SRC", anchored([".." / "nim-serialization"]), "x.nim"),
    ("NIM_JSON_SERIALIZATION_SRC", anchored([".." / "nim-json-serialization"]), "x.nim"),
    ("NIM_TOML_SERIALIZATION_SRC", anchored([".." / "nim-toml-serialization"]), "x.nim"),
    ("SSZ_SERIALIZATION_SRC", anchored([".." / "nim-ssz-serialization"]), "x.nim"),
    ("NIMCRYPTO_SRC", anchored(["libs" / "nimcrypto", ".." / "nimcrypto"]), "x.nim"),
    ("IO_MON_SRC", anchored([".." / "io-mon" / "src"]), "io_mon.nim"),
    ("BEARSSL_SRC", anchored([".." / "nim-bearssl", "libs" / "nim-bearssl"]), "bearssl.nim"),
    ("RESULTS_SRC", anchored(["libs" / "results" / "src"]), "results.nim"),
    ("STACKABLE_HOOKS_SRC", anchored([
      ".." / "nim-stackable-hooks" / "src",
    ]), "stackable_hooks.nim"),
    ("GOSTI_SRC", anchored([".." / "gosti" / "src"]), "gosti.nim"),
    ("SHM_QUEUE_SRC", anchored([".." / "nim-shm-queue" / "src"]), "shm_queue.nim"),
    ("SHM_GSET_SRC", anchored([".." / "nim-shm-gset" / "src"]), "shm_gset.nim"),
    ("CLI_SPEC_SRC", anchored([".." / "nim-cli-spec" / "src"]), "clispec.nim"),
  ]
  for spec in specs:
    if spec.envName in SiblingFirstPackageEnvNames:
      resolved = resolveSiblingFirstPackagePath(reprobuildRoot,
        spec.envName, spec.candidates, spec.marker)
    else:
      resolved = pinCheckedSiblingRoot(reprobuildRoot,
        spec.envName, resolveBootstrapPackagePath(spec.envName, spec.candidates))
  for adapterPath in [resolveCtTestRunnerAdapterPath(reprobuildRoot)]:
    discard
  runquotaRoot = pinCheckedSiblingRoot(reprobuildRoot,
    "RUNQUOTA_SRC", resolveRunquotaRoot(reprobuildRoot, consumerParent))
'''

CONFIG_TEXT = '''\
proc observeSibling(sibling: string): SiblingObservation =
  discard

let ioMonSrc = block:
  ".." / "io-mon" / "src"
if repoFileExists(ioMonSrc / "io_mon.nim"):
  if ioMonSrc == ".." / "io-mon" / "src":
    let choice = chooseSiblingSource(policy,
      observeSibling(ioMonSrc, envPinPresent = false, policy))

addPackagePath("STACKABLE_HOOKS_SRC", [
  ".." / "nim-stackable-hooks" / "src",
], "stackable_hooks.nim")

proc addSiblingFirstPackagePath(sibling, envName, marker: string) =
  let choice = chooseSiblingSource(policy,
    observeSibling(sibling, envPinPresent, policy))

addSiblingFirstPackagePath(".." / "nim-shm-queue" / "src", "SHM_QUEUE_SRC",
  "shm_queue.nim")
addSiblingFirstPackagePath(".." / "nim-shm-gset" / "src", "SHM_GSET_SRC",
  "shm_gset.nim")
addSiblingFirstPackagePath(".." / "nim-cli-spec" / "src", "CLI_SPEC_SRC",
  "clispec.nim")
addSiblingFirstPackagePath(".." / "nim-entrypoints" / "src", "ENTRYPOINTS_SRC",
  "entrypoints.nim")
# addSiblingFirstPackagePath(".." / "nim-commented-out", "X_SRC", "x.nim")
addSiblingFirstPackagePath(".." / "nim-confutils", "CONFUTILS_SRC",
  "confutils.nim")
'''


class CheckJudgedSiblings(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='judged-siblings-')
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / 'reprobuild'
        self.write(ENGINE, ENGINE_TEXT)
        self.write('config.nims', CONFIG_TEXT)
        self.write('libs/repro_core/src/repro_core/sibling_source_policy.nim',
                    'proc chooseSiblingSource*(policy: SiblingPolicy): SiblingChoice =\n  discard\n')

    def write(self, relative, text):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def edit(self, relative, old, new):
        path = self.source / relative
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def check(self, *extra):
        argv = [sys.executable, '-I', str(CHECK), '--source', str(self.source), *extra]
        return subprocess.run(argv, text=True, capture_output=True, timeout=60)

    def test_the_real_list_matches_a_source_of_the_pinned_shape(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('matches the 18 siblings', result.stdout)

    def test_a_nested_or_vendored_candidate_is_not_a_judged_sibling(self):
        # `../codetracer/libs/<pkg>`, `libs/<pkg>` and the CodeTracer seam's
        # `<root> / "reprobuild-ct-test-runner" / "libs" / ...` are not
        # checkouts directly in a workspace root; the real list leaves them
        # out, and the check agrees (the test above passes without them).
        result = self.check()
        for name in ('codetracer', 'reprobuild-ct-test-runner', 'results', 'nim-commented-out'):
            self.assertNotIn(name, result.stdout)

    def test_a_new_spec_the_engine_judges_fails(self):
        self.edit(ENGINE, '    ("GOSTI_SRC",',
                  '    ("FOO_SRC", anchored([".." / "nim-foo" / "src"]), "foo.nim"),\n'
                  '    ("GOSTI_SRC",')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing from the list: nim-foo', result.stderr)

    def test_a_renamed_runquota_candidate_fails(self):
        self.edit(ENGINE, 'anchorRoot.parentDir / "runquota"', 'anchorRoot.parentDir / "run-quota"')
        self.edit(ENGINE, 'consumerParent / "runquota"', 'consumerParent / "run-quota"')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing from the list: run-quota', result.stderr)
        self.assertIn('not judged by the source: runquota', result.stderr)

    def test_a_new_sibling_first_package_in_config_nims_fails(self):
        self.write('config.nims', CONFIG_TEXT +
                    'addSiblingFirstPackagePath(".." / "nim-new" / "src", "NEW_SRC",\n  "new.nim")\n')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing from the list: nim-new', result.stderr)

    def test_a_listed_name_the_source_no_longer_judges_fails(self):
        self.edit(ENGINE, '    ("GOSTI_SRC", anchored([".." / "gosti" / "src"]), "gosti.nim"),\n', '')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('not judged by the source: gosti', result.stderr)

    def test_a_judging_call_at_an_unknown_site_fails(self):
        self.write('libs/repro_core/src/repro_core/elsewhere.nim',
                    'proc judgeElsewhere*() =\n  discard chooseSiblingSource(spSibling)\n')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('elsewhere.nim:2 calls chooseSiblingSource in judgeElsewhere', result.stderr)

    def test_a_judging_call_in_a_test_directory_is_not_a_site(self):
        self.write('libs/repro_core/tests/t_policy.nim',
                    'proc t() =\n  discard chooseSiblingSource(spSibling)\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_engine_judge_called_from_another_routine_fails(self):
        self.write(ENGINE, ENGINE_TEXT +
                    '\nproc elsewhere() =\n  discard pinCheckedSiblingRoot("", "X_SRC", "")\n')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('pinCheckedSiblingRoot is called from elsewhere', result.stderr)

    def test_a_moved_specs_list_fails_instead_of_passing(self):
        self.edit(ENGINE, '  let specs: seq[SiblingSpec]', '  let packageSpecs: seq[SiblingSpec]')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('has no `let specs` list', result.stderr)

    def test_a_judge_call_naming_no_sibling_fails(self):
        self.edit(ENGINE, 'resolveRunquotaRoot(reprobuildRoot, consumerParent)', 'someRoot')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('judges no sibling this check can name', result.stderr)

    def test_a_missing_engine_file_fails(self):
        (self.source / ENGINE).unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('is missing from', result.stderr)

    def test_a_script_without_the_list_fails(self):
        script = self.source / 'step.sh'
        script.write_text('#!/usr/bin/env bash\nexit 0\n')
        result = self.check('--script', str(script))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('has no JUDGED_SIBLINGS', result.stderr)

    def test_rev_without_fetch_is_a_usage_error(self):
        result = self.check('--rev', 'a' * 40)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
