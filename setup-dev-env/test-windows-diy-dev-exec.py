"""Exercise the windows-diy flavor's dev-exec wrappers with real PowerShell.

The action's actual "Install dev-exec wrapper (windows-diy)" step runs
unchanged under pwsh with a private RUNNER_TEMP and GITHUB_PATH. Nothing is
mocked: the wrappers it writes run real commands through real pwsh (and, on
Windows, real cmd.exe). The checks:

- each run writes its wrappers into a directory of its own under RUNNER_TEMP
  and appends that directory to GITHUB_PATH;
- the PowerShell wrapper (what `dev-exec` resolves to in a pwsh step on
  Windows, the default shell there) forwards every argument unchanged and exiting with the command's status;
- a stale `dev-exec.ps1` in a directory later on PATH, as a reprobuild-flavor
  job used to leave in %USERPROFILE%\\.local\\bin, is not the one that runs;
- tokens PowerShell's parameter binder would split (`-d:release` reaches a
  script's `$args` as `-d:` and `release`) reach the command intact, through
  the in-process call a pwsh step makes and through the `dev-exec.cmd`
  trampoline;
- on Windows, the `dev-exec.cmd` trampoline forwards status the same way.

pwsh must be on PATH; GitHub-hosted Ubuntu and Windows images carry it.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
STEP = 'Install dev-exec wrapper (windows-diy)'
WINDOWS = os.name == 'nt'
# The name a pwsh step types. Windows pwsh does not treat the extensionless
# bash wrapper as executable, so `dev-exec` resolves to `dev-exec.ps1` there,
# the same lookup that picked a stale `dev-exec.ps1` on the runners. pwsh on
# Linux/macOS would run the extensionless file instead, so off Windows the
# PowerShell wrapper is named explicitly; PATH order is still what decides
# which `dev-exec.ps1` runs.
PS_NAME = 'dev-exec' if WINDOWS else 'dev-exec.ps1'


# Arguments typed bare in a pwsh step, as a Nim build writes them. PowerShell
# splits `-d:release`, `-x:y`, `-I:C:\\inc` etc. into two `$args` elements; the
# `--x:y` and `/x:y` forms stay whole in-process but `pwsh -File` splits them.
BARE_ARGUMENTS = ['--path:src', '-d:release', '-x:y', '/opt:val', '--daemon=off',
                  'a:b', '-I:C:\\inc', '-x:-y', '-x:1.5']
# Arguments that need quoting to be typed at all; they must survive as well.
QUOTED_ARGUMENTS = ['', 'with space', '--', 'quoted:arg', '-quoted:value']
ARGV_PROGRAM = 'import json, sys; print(json.dumps(sys.argv[1:]))'


def step_body():
    source = (HERE / 'action.yml').read_text()
    step = source.split('    - name: ' + STEP + '\n', 1)[1]
    step = step.split('    - name: ', 1)[0].split('    # ---', 1)[0]
    body = step.split('      run: |\n', 1)[1]
    return '\n'.join(line[8:] if line.startswith('        ') else ''
                      for line in body.splitlines()) + '\n'


class WindowsDiyDevExec(unittest.TestCase):
    def setUp(self):
        self.pwsh = shutil.which('pwsh')
        if self.pwsh is None:
            self.fail('pwsh is not on PATH; this test runs the real step')
        self.temporary = tempfile.TemporaryDirectory(prefix='windows-diy-dev-exec-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runner_temp = self.root / 'runner-temp'
        self.runner_temp.mkdir()
        self.github_path = self.root / 'github-path'
        self.github_path.write_text('')
        self.script = self.root / 'step.ps1'
        self.script.write_text(step_body())

    def install(self):
        environment = dict(os.environ, RUNNER_TEMP=str(self.runner_temp),
                            GITHUB_PATH=str(self.github_path))
        run = subprocess.run([self.pwsh, '-NoLogo', '-NoProfile', '-File',
                              str(self.script)], cwd=self.root, env=environment,
                              text=True, capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return Path(self.github_path.read_text().splitlines()[-1])

    def pwsh_in(self, path_dirs, command):
        environment = dict(os.environ,
                            PATH=os.pathsep.join([str(d) for d in path_dirs] +
                                                [os.environ['PATH']]))
        return subprocess.run([self.pwsh, '-NoLogo', '-NoProfile', '-Command',
                                command], cwd=self.root, env=environment,
                              text=True, capture_output=True, timeout=60)

    def test_each_run_gets_its_own_directory_under_runner_temp(self):
        first = self.install()
        second = self.install()
        self.assertNotEqual(first, second)
        for directory in (first, second):
            self.assertEqual(directory.parent, self.runner_temp)
            self.assertEqual(sorted(p.name for p in directory.iterdir()),
                              ['dev-exec', 'dev-exec.cmd', 'dev-exec.ps1'])
        self.assertEqual(self.github_path.read_text().splitlines(),
                          [str(first), str(second)])

    def test_powershell_forwards_arguments_and_status(self):
        directory = self.install()
        python = sys.executable.replace("'", "''")
        program = 'import sys; print("|".join(sys.argv[1:])); sys.exit(7)'
        run = self.pwsh_in([directory],
                            PS_NAME + " '" + python + "' -c '" + program +
                            "' plain 'with space' ''; exit $LASTEXITCODE")
        self.assertEqual(run.returncode, 7, run.stdout + run.stderr)
        self.assertEqual(run.stdout.strip(), 'plain|with space|')

    def test_a_stale_wrapper_later_on_path_does_not_run(self):
        directory = self.install()
        stale = self.root / 'stale-local-bin'
        stale.mkdir()
        (stale / 'dev-exec.ps1').write_text(
            'Write-Output "stale wrapper ran"\nexit 99\n')
        python = sys.executable.replace("'", "''")
        run = self.pwsh_in([directory, stale],
                            PS_NAME + " '" + python + "' -c 'print(42)'; "
                            'exit $LASTEXITCODE')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.strip(), '42')
        self.assertNotIn('stale wrapper ran', run.stdout)

    def test_powershell_keeps_colon_arguments_intact(self):
        # The regression: `dev-exec nim c --path:src` reached Nim as
        # `--path:` plus `src` (and `-d:release` as `-d:` plus `release`).
        directory = self.install()
        python = sys.executable.replace("'", "''")
        quoted = ' '.join("'" + a.replace("'", "''") + "'" for a in QUOTED_ARGUMENTS)
        run = self.pwsh_in([directory],
                            PS_NAME + " '" + python + "' -c '" + ARGV_PROGRAM + "' " +
                            ' '.join(BARE_ARGUMENTS) + ' ' + quoted +
                            '; exit $LASTEXITCODE')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), BARE_ARGUMENTS + QUOTED_ARGUMENTS)

    def test_no_command_is_refused(self):
        directory = self.install()
        run = self.pwsh_in([directory], PS_NAME + '; exit $LASTEXITCODE')
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('no command given', run.stdout + run.stderr)

    @unittest.skipUnless(WINDOWS, 'cmd.exe exists only on Windows')
    def test_cmd_trampoline_forwards_status(self):
        directory = self.install()
        environment = dict(os.environ,
                            PATH=str(directory) + os.pathsep + os.environ['PATH'])
        run = subprocess.run(['cmd.exe', '/d', '/c', 'dev-exec.cmd',
                              sys.executable, '-c',
                              'import sys; print("ok"); sys.exit(5)'],
                              cwd=self.root, env=environment, text=True,
                              capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 5, run.stdout + run.stderr)
        self.assertEqual(run.stdout.strip(), 'ok')

    @unittest.skipUnless(WINDOWS, 'cmd.exe exists only on Windows')
    def test_cmd_trampoline_keeps_colon_arguments_intact(self):
        directory = self.install()
        environment = dict(os.environ,
                            PATH=str(directory) + os.pathsep + os.environ['PATH'])
        # Every one of these reaches `pwsh -File` unless the trampoline avoids
        # it, and -File splits the colon forms in two and drops the colon.
        arguments = BARE_ARGUMENTS + QUOTED_ARGUMENTS
        run = subprocess.run(['cmd.exe', '/d', '/c', 'dev-exec.cmd',
                              sys.executable, '-c', ARGV_PROGRAM, *arguments],
                              cwd=self.root, env=environment, text=True,
                              capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), arguments)


if __name__ == '__main__':
    unittest.main()
