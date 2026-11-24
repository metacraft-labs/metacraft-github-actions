"""Check that the windows-diy flavor hands later steps env.ps1's PATH order.

"Source env.ps1 + persist env (windows-diy)" dot-sources the project's
env.ps1 and writes the PATH entries it added to `$GITHUB_PATH`. The runner
prepends each line of that file ahead of the lines before it, so the file's
last line ends up first on PATH. The step used to write the entries in
env.ps1's order, which reversed their precedence for every later step: on a
Windows runner that still held a GNAT install, GNAT's gcc (no static pthread)
shadowed the WinLibs gcc env.ps1 puts ahead of it, and Nim links failed with
"cannot find -lpthread".

The check runs the real step body under pwsh with a stand-in env.ps1 that
prepends `first;second;third` to PATH, rebuilds PATH from the `$GITHUB_PATH`
file the way the runner does, and requires the three in env.ps1's order ahead
of the original PATH. A negative control runs the step body as it was before
the fix and requires the reversed order, so a harness that stopped modelling
the runner cannot pass.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ACTION = HERE / 'action.yml'
STEP = 'Source env.ps1 + persist env (windows-diy)'

# The PATH branch as it stood before the fix, for the negative control.
OLD_PATH_BRANCH = '''\
foreach ($e in $newEntries) {
  if ($e -and ($oldEntries -notcontains $e)) {
    Add-Content -Path $env:GITHUB_PATH -Value $e
  }
}
'''


def step_body():
    step = ACTION.read_text(encoding='utf-8').split('    - name: ' + STEP + '\n', 1)[1]
    step = step.split('\n    - name: ', 1)[0]
    body = step.split('      run: |\n', 1)[1]
    return '\n'.join(line[8:] if line.startswith('        ') else line
                     for line in body.splitlines()) + '\n'


def old_step_body():
    """The step with its PATH branch replaced by the pre-fix loop."""
    body = step_body()
    start = body.index('$added = ')
    end = body.index('} else {', start)
    # Re-indent the old loop to the branch's indentation.
    indent = ' ' * 6
    old = ''.join(indent + line + '\n' for line in OLD_PATH_BRANCH.splitlines())
    old = indent + '$newEntries = $value.Split([IO.Path]::PathSeparator)\n' + old
    end = body.rindex('\n', start, end) + 1
    return body[:start] + old.lstrip() + body[end:]


def runner_path(github_path_text, original):
    """PATH as the runner builds it: GITHUB_PATH lines, last line first."""
    lines = [line for line in github_path_text.splitlines() if line]
    prepend = []
    for line in lines:
        if line in prepend:
            prepend.remove(line)
        prepend.append(line)
    return list(reversed(prepend)) + original


class WindowsDiyPathOrder(unittest.TestCase):
    def setUp(self):
        self.pwsh = shutil.which('pwsh')
        if self.pwsh is None:
            self.fail('pwsh is not on PATH; this test runs the real step')
        temporary = tempfile.TemporaryDirectory(prefix='windows-diy-path-order-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dirs = [str(self.root / name) for name in ('first', 'second', 'third')]
        self.env_ps1 = self.root / 'env.ps1'
        sep = os.pathsep
        self.env_ps1.write_text(
            '$env:PATH = "' + sep.join(self.dirs) + sep + '" + $env:PATH\n',
            encoding='utf-8')

    def run_step(self, body):
        script = self.root / 'step.ps1'
        script.write_text(body, encoding='utf-8')
        github_path = self.root / 'github_path'
        github_env = self.root / 'github_env'
        github_path.write_text('', encoding='utf-8')
        github_env.write_text('', encoding='utf-8')
        env = dict(os.environ,
                   ENV_PS1_PATH=str(self.env_ps1),
                   GITHUB_PATH=str(github_path),
                   GITHUB_ENV=str(github_env))
        subprocess.run([self.pwsh, '-NoProfile', '-NonInteractive', '-File', str(script)],
                       env=env, check=True)
        original = os.environ['PATH'].split(os.pathsep)
        return runner_path(github_path.read_text(encoding='utf-8'), original), original

    def test_later_steps_see_env_ps1_order(self):
        path, original = self.run_step(step_body())
        self.assertEqual(path[:3], self.dirs)
        self.assertEqual(path[3:], original)

    def test_the_pre_fix_step_reverses_the_order(self):
        # Negative control: the loop the step carried before the fix.
        body = old_step_body()
        self.assertIn('$newEntries', body)
        self.assertNotIn('$added', body)
        path, _ = self.run_step(body)
        self.assertEqual(path[:3], list(reversed(self.dirs)))


if __name__ == '__main__':
    unittest.main()
