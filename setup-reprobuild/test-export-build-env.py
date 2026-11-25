"""A source build hands its build environment to later steps only when asked.

Property protected: with `export-build-env: false`, the source build of the
`repro` CLI adds nothing to the job environment except what locates the CLI.
That means its `build/bin` directory goes on `$GITHUB_PATH` and, on
Linux/macOS, `REPROBUILD_NIX_DAEMON_BIN` goes to `$GITHUB_ENV`. Every other
variable and PATH entry the build would have exported goes to the files the
`build-env-dir` output names: `env` (`NAME=VALUE` lines) and `path` (one
directory per line). The RunQuota daemon, the bootstrap compiler, the sibling
sources and the toolchain directories all go there. With the default, `true`,
they reach later steps exactly as before.

Why: a later step that builds its own toolchain refuses an inherited one.
nim-libvterm's native Windows ARM64 leg builds RunQuota natively, and its
`Build-NativeRunquota` refuses an inherited `RUNQUOTAD_BIN` or `LIBRARY_PATH`.
setup-dev-env built the x64 CLI from source under emulation and exported both,
so the leg failed. setup-dev-env still needs them for its own `repro exec`
check, so they are kept in the files rather than dropped.

How: the two source-build steps' real bodies run, as in
test-source-build-env.py (bash) and test-windows-source-build-nim.py (pwsh),
whose harnesses and stand-ins this suite reuses and whose docstrings explain
them. The Windows stand-in for `build-runquota-bootstrap.ps1` sets the two
RunQuota variables in the step's process, as the real script does. The step
that turns the input into `build-env-dir` runs for real too.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ACTION = HERE / 'action.yml'
DECIDE_STEP = 'Choose where the source build environment goes'


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


unix = load('test-source-build-env')
windows = load('test-windows-source-build-nim')


def read_env(path):
    result = {}
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            if line:
                name, _, value = line.partition('=')
                result[name.upper() if os.name == 'nt' else name] = value
    return result


def read_lines(path):
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding='utf-8').splitlines() if line]


class DecideBuildEnvironment(unittest.TestCase):
    """The step that turns `export-build-env` into `build-env-dir`."""

    def run_decide(self, value):
        # Resolve bash from PATH before handing it to subprocess. On Windows a
        # bare name goes to CreateProcess, which searches System32 before
        # PATH and finds WSL's `bash.exe` launcher instead of the Git Bash
        # that runs the step. On windows-latest it exits 1 without running
        # the step and leaves stderr empty.
        bash = shutil.which('bash')
        self.assertIsNotNone(bash, 'the suite needs bash')
        with tempfile.TemporaryDirectory(prefix='repro-build-env-decide-') as root:
            root = Path(root)
            output = root / 'output'
            output.write_text('')
            done = subprocess.run(
                [bash, '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                  unix.step_body(DECIDE_STEP)],
                env={'PATH': os.environ['PATH'], 'RUNNER_TEMP': str(root),
                  'GITHUB_OUTPUT': str(output), 'EXPORT_BUILD_ENV': value},
                capture_output=True, text=True, timeout=60)
            outputs = read_env(output)
            directory = outputs.get('dir', '')
            made = bool(directory) and Path(directory).is_dir()
            return done, directory, made

    def test_true_keeps_the_job_environment(self):
        done, directory, _ = self.run_decide('true')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(directory, '')

    def test_false_names_a_new_directory(self):
        done, directory, made = self.run_decide('false')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(made, 'build-env-dir was not created: ' + repr(directory))

    def test_a_misspelt_value_fails(self):
        done, _, _ = self.run_decide('no')
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("export-build-env must be 'true' or 'false'", done.stderr)


@unittest.skipIf(os.name == 'nt', 'the Linux/macOS step; its stand-ins are POSIX scripts')
class UnixSourceBuild(unix.SourceBuildEnvironment):
    DEV_SHELL = dict(unix.SIBLING_FIRST, NIMCRYPTO_SRC='/nix/store/ffff-nimcrypto',
        BEARSSL_SRC='/nix/store/gggg-nim-bearssl')

    # The inherited tests are test-source-build-env.py's; run them there.
    test_every_sibling_first_source_reaches_later_steps = None
    test_a_dev_shell_without_them_forwards_none_and_still_succeeds = None
    test_the_required_sources_are_still_required = None

    def test_by_default_the_build_environment_reaches_later_steps(self):
        result, exported = self.run_step(self.DEV_SHELL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(exported.get('RUNQUOTAD_BIN'), str(self.tools / 'runquotad'))
        self.assertEqual(exported.get('NIMCRYPTO_SRC'), '/nix/store/ffff-nimcrypto')
        self.assertIn('REPRO_FOREIGN_ENV_BASH', exported)

    def test_without_export_only_the_cli_reaches_later_steps(self):
        build_env = self.root / 'build-env'
        build_env.mkdir()
        result, exported = self.run_step(self.DEV_SHELL, {'BUILD_ENV_DIR': str(build_env)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        helper = self.workspace / '.reprobuild-src' / 'build' / 'bin' / 'reprobuild-nix-daemon'
        self.assertEqual(exported, {'REPROBUILD_NIX_DAEMON_BIN': str(helper)})
        self.assertEqual(read_lines(self.github_path), [str(helper.parent)])
        kept = read_env(build_env / 'env')
        self.assertEqual(kept.get('RUNQUOTAD_BIN'), str(self.tools / 'runquotad'))
        self.assertEqual(kept.get('NIMCRYPTO_SRC'), '/nix/store/ffff-nimcrypto')
        for name, value in unix.SIBLING_FIRST.items():
            self.assertEqual(kept.get(name), value, name)
        self.assertIn('REPRO_FOREIGN_ENV_BASH', kept)
        self.assertNotIn('REPROBUILD_NIX_DAEMON_BIN', kept)
        self.assertEqual(read_lines(build_env / 'path'), [str(self.tools)])


BOOTSTRAP_STAND_IN = '''\
$env:RUNQUOTAD_BIN = Join-Path $env:RUNNER_TEMP 'runquotad.exe'
$env:RUNQUOTA_BIN = Join-Path $env:RUNNER_TEMP 'runquota.exe'
'''


class WindowsSourceBuild(windows.WindowsSourceBuildNim):
    # The inherited tests are test-windows-source-build-nim.py's; run them there.
    test_later_steps_get_no_nim_compiler = None
    test_a_nim_compiler_env_ps1_sets_is_not_forwarded = None
    test_the_old_export_is_caught = None
    test_a_forwarded_env_ps1_value_is_caught = None

    def setUp(self):
        super().setUp()
        (self.action_path / 'build-runquota-bootstrap.ps1').write_text(
            BOOTSTRAP_STAND_IN, encoding='utf-8')
        self.extra = {'RUNNER_TEMP': str(self.root)}

    def repro_bin(self):
        return self.workspace / '.reprobuild-src' / 'build' / 'bin'

    def test_by_default_the_build_environment_reaches_later_steps(self):
        env = self.run_step(windows.step_body(), extra_env=self.extra)
        self.assertEqual(env.get('RUNQUOTAD_BIN'), str(self.root / 'runquotad.exe'), env)
        self.assertEqual(env.get('RUNQUOTA_BIN'), str(self.root / 'runquota.exe'), env)
        self.assert_reached_the_exports(env)
        # The step splits PATH on `;`, so only a Windows run sees the
        # toolchain directory env.ps1 added as a separate entry.
        if windows.WINDOWS:
            paths = read_lines(self.github_path)
            self.assertTrue(any(os.path.samefile(p, self.toolchain) for p in paths), paths)

    def test_without_export_only_the_cli_reaches_later_steps(self):
        build_env = self.root / 'build-env'
        build_env.mkdir()
        env = self.run_step(windows.step_body(),
                            extra_env=dict(self.extra, BUILD_ENV_DIR=str(build_env)))
        self.assertEqual(env, {})
        paths = read_lines(self.github_path)
        self.assertEqual(len(paths), 1, paths)
        self.assertTrue(os.path.samefile(paths[0], self.repro_bin()), paths)
        kept = read_env(build_env / 'env')
        self.assertEqual(kept.get('RUNQUOTAD_BIN'), str(self.root / 'runquotad.exe'), kept)
        self.assertEqual(kept.get('RUNQUOTA_BIN'), str(self.root / 'runquota.exe'), kept)
        self.assertEqual(kept.get('BEARSSL_SRC'), str(self.root / 'bearssl'), kept)
        self.assertIn('REPRO_BOOTSTRAP_CC', kept)
        self.assertNotIn('REPRO_NIM_COMPILER', kept)
        if windows.WINDOWS:
            kept_paths = read_lines(build_env / 'path')
            self.assertTrue(any(os.path.samefile(p, self.toolchain) for p in kept_paths), kept_paths)


class Wiring(unittest.TestCase):
    """Both source-build steps take the directory the deciding step chose."""

    def step(self, name):
        text = ACTION.read_text(encoding='utf-8')
        return text.split('    - name: ' + name + '\n', 1)[1].split('\n    - name: ', 1)[0]

    def test_the_build_steps_receive_the_directory(self):
        for name in ('Build repro CLI (Linux/macOS)', 'Build repro CLI (Windows)'):
            self.assertTrue('BUILD_ENV_DIR: ${{ steps.build-env.outputs.dir }}' in self.step(name), name)

    def test_the_input_reaches_the_deciding_step(self):
        step = self.step(DECIDE_STEP)
        self.assertIn('id: build-env', step)
        self.assertIn('EXPORT_BUILD_ENV: ${{ inputs.export-build-env }}', step)

    def test_the_directory_is_an_output(self):
        text = ACTION.read_text(encoding='utf-8')
        outputs = text.split('\noutputs:\n', 1)[1].split('\nruns:\n', 1)[0]
        self.assertTrue('value: ${{ steps.build-env.outputs.dir }}' in outputs, 'no build-env-dir output')


if __name__ == '__main__':
    unittest.main()
