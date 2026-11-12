"""Check that the reprobuild flavor's PowerShell wrappers forward arguments intact.

PowerShell's parameter binder rewrites a bare `-name:value` token into two
`$args` elements, and `pwsh -File` splits `--name:value` the same way and drops
the colon. The wrapper's `repro exec ... pwsh -File dev-exec-run.ps1` hop used to
turn `dev-exec nim c --path:src` into `nim c --path src`, which Nim rejects with
`argument for command line option expected: '--path'`.

The generated `dev-exec.ps1`, `dev-exec-run.ps1` and `dev-exec.cmd` are lifted
verbatim from the action's "Install dev-exec wrapper (reprobuild)" step and run
under real pwsh (and real cmd.exe on Windows), with a real child process that
reports its argv as JSON.

The one stand-in is `repro`: a few lines of Python that implement only the
`repro exec <root> -- <command...>` contract the wrapper relies on (run the
command with its arguments unchanged) instead of activating a Reprobuild
environment. That is justified because the defect lives in how the wrapper
hands arguments to `repro`, not in `repro`; this test needs no SDK, so it runs
on every platform where pwsh exists. test-repro-wrapper-cwd.py covers the same
wrappers against the real released CLI on Windows.
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
STEP = 'Install dev-exec wrapper (reprobuild)'
WINDOWS = os.name == 'nt'

# Typed bare in a pwsh step: the binder splits `-name:value`. The `--name:value`
# and `/name:value` forms are split by `pwsh -File` only.
BARE_ARGUMENTS = ['--path:src', '-d:release', '-x:y', '/opt:val', '--daemon=off',
                  'a:b', '-I:C:\\inc', '-x:-y', '-x:1.5']
# These need quoting to be typed at all, and must survive too.
QUOTED_ARGUMENTS = ['', 'with space', '--', 'quoted:arg', '-quoted:value']
ARGV_PROGRAM = 'import json, sys; print(json.dumps(sys.argv[1:]))'

FAKE_REPRO = '''import subprocess, sys
# repro exec <root> -- <command...>
if len(sys.argv) < 5 or sys.argv[1] != 'exec' or sys.argv[3] != '--':
    sys.exit('fake repro: unexpected arguments: ' + repr(sys.argv[1:]))
sys.exit(subprocess.call(sys.argv[4:]))
'''


def heredoc(step, name):
    """The text the step writes to `$WIN_BIN_DIR/<name>`, dedented as bash does."""
    marker = 'cat > "$WIN_BIN_DIR/' + name + '" <<\'EOF\'\n'
    body = step.split(marker, 1)[1].split('\n        EOF\n', 1)[0]
    return '\n'.join(line[8:] for line in body.splitlines()) + '\n'


def reprobuild_step():
    source = (HERE / 'action.yml').read_text(encoding='utf-8')
    step = source.split('    - name: ' + STEP + '\n', 1)[1]
    return step.split('    - name: ', 1)[0]


class ReprobuildPowerShellArguments(unittest.TestCase):
    def setUp(self):
        self.pwsh = shutil.which('pwsh')
        if self.pwsh is None:
            self.fail('pwsh is not on PATH; this test runs the real wrappers')
        temporary = tempfile.TemporaryDirectory(prefix='reprobuild-ps1-args-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.wrappers = self.root / 'wrappers'
        self.wrappers.mkdir()
        step = reprobuild_step()
        for name in ('dev-exec.ps1', 'dev-exec-run.ps1', 'dev-exec.cmd'):
            (self.wrappers / name).write_text(heredoc(step, name), encoding='utf-8',
                                              newline='\n')
        (self.wrappers / 'dev-exec.project-root').write_text(str(self.root) + '\n')
        fake = self.root / 'fake-repro.py'
        fake.write_text(FAKE_REPRO)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        if WINDOWS:
            (self.bin / 'repro.cmd').write_text(
                '@"' + sys.executable + '" "' + str(fake) + '" %*\r\n')
        else:
            launcher = self.bin / 'repro'
            launcher.write_text('#!/bin/sh\nexec "' + sys.executable + '" "' +
                                str(fake) + '" "$@"\n')
            launcher.chmod(0o755)
        self.env = dict(os.environ,
                        PATH=os.pathsep.join([str(self.bin), os.environ['PATH']]))

    def in_process(self, arguments_source):
        """What a pwsh step does: call the wrapper script by path."""
        python = sys.executable.replace("'", "''")
        wrapper = str(self.wrappers / 'dev-exec.ps1').replace("'", "''")
        command = ("& '" + wrapper + "' '" + python + "' -c '" + ARGV_PROGRAM +
                   "' " + arguments_source + '; exit $LASTEXITCODE')
        return subprocess.run([self.pwsh, '-NoLogo', '-NoProfile', '-Command', command],
                              cwd=self.root, env=self.env, text=True,
                              capture_output=True, timeout=120)

    def test_colon_arguments_survive_the_wrapper_and_the_file_hop(self):
        quoted = ' '.join("'" + a.replace("'", "''") + "'" for a in QUOTED_ARGUMENTS)
        run = self.in_process(' '.join(BARE_ARGUMENTS) + ' ' + quoted)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), BARE_ARGUMENTS + QUOTED_ARGUMENTS)

    def test_status_still_propagates(self):
        python = sys.executable.replace("'", "''")
        wrapper = str(self.wrappers / 'dev-exec.ps1').replace("'", "''")
        run = subprocess.run(
            [self.pwsh, '-NoLogo', '-NoProfile', '-Command',
             "& '" + wrapper + "' '" + python + "' -c 'import sys; sys.exit(7)' "
             '-d:release; exit $LASTEXITCODE'],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=120)
        self.assertEqual(run.returncode, 7, run.stdout + run.stderr)

    @unittest.skipUnless(WINDOWS, 'cmd.exe exists only on Windows')
    def test_cmd_trampoline_keeps_colon_arguments_intact(self):
        arguments = BARE_ARGUMENTS + QUOTED_ARGUMENTS
        run = subprocess.run(['cmd.exe', '/d', '/c', str(self.wrappers / 'dev-exec.cmd'),
                              sys.executable, '-c', ARGV_PROGRAM, *arguments],
                              cwd=self.root, env=self.env, text=True,
                              capture_output=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), arguments)


if __name__ == '__main__':
    unittest.main()
