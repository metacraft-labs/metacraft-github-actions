"""Test the actual parent step's refusal and exit-status boundary.

Only the SDK CLI is a stand-in: controlled responses exercise cases a real
supported SDK must not produce. The positive forwards the step's real command
to the real Bash process. This tests action routing, not Reprobuild's provider
evaluation, installed closure, native Windows execution, or cache reuse.

The generated-wrapper argument controls also use a CLI argument recorder:
the SDK has no argument-inspection operation, and provisioning a package would
test a different boundary. The actual installer, wrappers and child processes
run unchanged. Real SDK activation/cwd/status coverage remains in
test-repro-wrapper-cwd.py, which also runs these controls on native Windows.
"""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
STEP = 'Verify Reprobuild development-environment execution'
WITNESS = 'setup-dev-env: repro exec witness v1'


def parent_step():
    source = (HERE / 'action.yml').read_text()
    step = source.split('    - name: ' + STEP + '\n', 1)[1]
    return step.split('    - name: ', 1)[0]


class ExecCapability(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='parent-exec-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.bash = shutil.which('bash')
        self.assertIsNotNone(self.bash)
        (self.tools / 'bash').symlink_to(self.bash)
        step = parent_step().split('      run: |\n', 1)[1]
        self.body = '\n'.join(line[8:] if line.startswith('        ') else ''
                              for line in step.splitlines()) + '\n'

    def run_step(self, response=None):
        if response is not None:
            cli = self.tools / 'repro'
            cli.write_text('#!' + self.bash + '\n' + response + '\n')
            cli.chmod(0o755)
        environment = dict(os.environ, PATH=str(self.tools))
        return subprocess.run([self.bash, '-c', self.body], cwd=self.root,
                              env=environment, text=True, capture_output=True,
                              timeout=10)

    def test_real_command_execution_accepts_ordinary_diagnostics(self):
        result = self.run_step('''set -eu
test "$1" = exec && test "$2" = --
shift 2
printf 'materializing declared environment\n'
exec "$@"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('materializing declared environment\n', result.stdout)
        self.assertIn(WITNESS + '\n', result.stdout)

    def test_lingering_child_holding_stdout_does_not_hang_the_step(self):
        # 2026-10-23: on Windows `repro exec` leaves runquotad.exe running with
        # the inherited stdout. A `$(...)` capture waits for EOF from every
        # writer, so every win-hms job sat in this step until its 240-minute
        # timeout. The step must wait for `repro exec` itself, not its children.
        result = self.run_step('''set -eu
test "$1" = exec && test "$2" = --
shift 2
( read -t 30 <> <(:) || true ) &
"$@"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(WITNESS + '\n', result.stdout)

    def test_false_success_with_global_help_is_refused(self):
        result = self.run_step("printf 'usage: repro <command>\n'; exit 0")
        self.assertEqual(result.returncode, 1)
        self.assertIn('usage: repro <command>\n', result.stdout)
        self.assertIn('without executing its witness command', result.stderr)

    def test_printed_witness_does_not_hide_cli_failure(self):
        result = self.run_step(
            f"printf '%s\\n' '{WITNESS}'; "
            "printf 'real exec failure\\n' >&2; exit 23")
        self.assertEqual(result.returncode, 23)
        self.assertIn(WITNESS + '\n', result.stdout)
        self.assertIn('real exec failure\n', result.stderr)
        self.assertIn('exit 23', result.stderr)

    def test_missing_exec_operation_preserves_refusal(self):
        result = self.run_step("printf 'unsupported exec\\n' >&2; exit 2")
        self.assertEqual(result.returncode, 2)
        self.assertIn('unsupported exec\n', result.stderr)

    def test_missing_cli_preserves_command_not_found(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 127)

    def test_success_without_witness_is_refused(self):
        result = self.run_step('exit 0')
        self.assertEqual(result.returncode, 1)

    def test_witness_requires_an_exact_line(self):
        result = self.run_step(f"printf 'prefix %s suffix\\n' '{WITNESS}'")
        self.assertEqual(result.returncode, 1)

    def test_native_crlf_witness_line_is_accepted(self):
        result = self.run_step(f"printf '%s\\r\\n' '{WITNESS}'")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_parent_runs_probe_after_preparation_before_publishing_wrapper(self):
        source = (HERE / 'action.yml').read_text()
        self.assertLess(source.index('Clone the siblings the repro.lock path did not provide'),
                        source.index(STEP))
        self.assertLess(source.index('Ensure the archive tools repro shells out to'),
                        source.index(STEP))
        self.assertLess(source.index(STEP), source.index('Install dev-exec wrapper (reprobuild)'))
        step = parent_step()
        self.assertIn("      if: ${{ inputs.env-flavor == 'reprobuild' }}\n", step)
        self.assertIn('      working-directory: ${{ steps.roots.outputs.consumer-directory }}\n', step)


class ProvisioningArguments(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wrapper-provisioning-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.consumer = self.root / 'consumer'
        self.consumer.mkdir()
        self.bash = shutil.which('bash')
        self.assertIsNotNone(self.bash)
        spec = importlib.util.spec_from_file_location(
            'native_status_fixture', HERE / 'test-windows-cmd-status.py')
        self.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.fixture)
        probe = self.root / 'record arguments.py'
        probe.write_text('import json,os,sys\nprint(json.dumps(sys.argv[1:]))\n'
                          'sys.exit(int(os.environ["GHA_ARGV_STATUS"]))\n',
                          encoding='utf-8', newline='\n')
        recorder = self.tools / 'repro'
        recorder.write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(sys.executable) +
                            ' ' + shlex.quote(str(probe)) + ' "$@"\n',
                            encoding='utf-8', newline='\n')
        recorder.chmod(0o755)
        (self.tools / 'repro.ps1').write_text(
            '& $env:GHA_ARGV_PYTHON $env:GHA_ARGV_SCRIPT @args\nexit $LASTEXITCODE\n',
            encoding='utf-8', newline='\n')
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        GHA_ARGV_PYTHON=sys.executable, GHA_ARGV_SCRIPT=str(probe))
        runner = self.root / 'runner temp'
        runner.mkdir()
        for name in ('github-env', 'github-path'):
            (self.root / name).touch()
        installer = self.root / 'install.sh'
        action = Path(os.environ.get('GHA_TEST_ACTION_YML', HERE / 'action.yml'))
        installer.write_text(self.fixture.installer_body(action), encoding='utf-8', newline='\n')
        installed = subprocess.run([self.bash, str(installer)], cwd=self.consumer,
            env=dict(self.env, RUNNER_OS='Windows' if os.name == 'nt' else 'Linux',
                      RUNNER_TEMP=str(runner), MCL_CONSUMER_ROOT=str(self.consumer),
                      GITHUB_ENV=str(self.root / 'github-env'),
                      GITHUB_PATH=str(self.root / 'github-path')),
            text=True, capture_output=True, timeout=10)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.wrapper = self.fixture.installed_wrapper_directory(
            self.root / 'github-path') / 'dev-exec'
        self.calls = 0

    def assert_arguments(self, tail, expected, status):
        commands = [('bash', [self.bash, str(self.wrapper), 'repro', *tail])]
        if os.name == 'nt':
            pwsh, cmd = shutil.which('pwsh'), shutil.which('cmd.exe')
            self.assertTrue(pwsh and cmd, 'native PowerShell and CMD are required')
            commands.append(('pwsh', [pwsh, '-NoProfile', '-File',
                                      str(self.wrapper.with_suffix('.ps1')), 'repro', *tail]))
            commands.append(('cmd', self.fixture.write_cmd_driver(
                self.root / ('case-' + str(self.calls) + '.cmd'),
                self.wrapper.with_suffix('.cmd'), ['repro', *tail], cmd)))
        self.calls += 1
        for name, argv in commands:
            with self.subTest(wrapper=name, arguments=tail, status=status):
                result = subprocess.run(argv, cwd=self.consumer,
                    env=dict(self.env, GHA_ARGV_STATUS=str(status)),
                    text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_default_leaves_project_provisioning_mode_unselected(self):
        for verb in ('build', 'test'):
            for status in (0, 19):
                tail = [verb, '', 'space argument']
                self.assert_arguments(tail, [*tail, '--daemon=off'], status)

    def test_explicit_modes_and_daemon_are_preserved(self):
        for verb in ('build', 'test'):
            for mode in ('path', 'nix', 'tarball', 'scoop', 'from-source'):
                tail = [verb, '--tool-provisioning=' + mode, '--daemon=auto',
                        '', 'space argument']
                self.assert_arguments(tail, tail, 19)

    def test_explicit_daemon_does_not_select_provisioning(self):
        for verb in ('build', 'test'):
            tail = [verb, '--daemon=require']
            self.assert_arguments(tail, tail, 0)


if __name__ == '__main__':
    unittest.main()
