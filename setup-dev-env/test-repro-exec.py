"""Test the actual parent step's refusal and exit-status boundary.

Only the SDK CLI is a stand-in: controlled responses exercise cases a real
supported SDK must not produce. The positive forwards the step's real command
to the real Bash process. This tests action routing, not Reprobuild's provider
evaluation, installed closure, native Windows execution, or cache reuse.
"""
import os
from pathlib import Path
import shutil
import subprocess
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


if __name__ == '__main__':
    unittest.main()
