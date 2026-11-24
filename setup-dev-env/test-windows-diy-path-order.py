"""Check the PATH the windows-diy flavor hands later steps.

"Source env.ps1 + persist env (windows-diy)" dot-sources the project's
env.ps1 and writes the PATH entries it added to `$GITHUB_PATH`. The runner
prepends each line of that file ahead of the lines before it, so the file's
last line ends up first on PATH. Two rules are checked:

- env.ps1's precedence is kept. Written in env.ps1's order the entries came
  out reversed: on a Windows runner that still held a GNAT install, GNAT's gcc
  (no static pthread) shadowed the WinLibs gcc env.ps1 puts ahead of it, and
  Nim links failed with "cannot find -lpthread".
- env.ps1's shims directory (`WINDOWS_DIY_SHIMS_DIR`) goes behind every other
  entry. Its shims are extensionless bash scripts; with the directory first,
  pwsh resolved `nim` to the shim and could not start it.
- each tool env.ps1 aliases resolves to the alias's target. env.ps1's PATH
  order alone puts tup's MSYS2 mingw64 bin, with a gcc.exe of its own, ahead
  of the WinLibs gcc it aliases; a local session never sees that because the
  alias wins there.

The check runs the real step body under pwsh with a stand-in env.ps1,
rebuilds PATH from the `$GITHUB_PATH` file the way the runner does, and
compares the result. A negative control runs the step body as it was before
either rule and requires the reversed order, so a harness that stopped
modelling the runner cannot pass.
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

# The PATH branch as it stood before either rule, for the negative control.
OLD_PATH_BRANCH = '''\
$newEntries = $value.Split([IO.Path]::PathSeparator)
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
    lines = [
        line[8:] if line.startswith('        ') else line
        for line in body.splitlines()
    ]
    return '\n'.join(lines) + '\n'


def old_step_body():
    """The step with its PATH branch replaced by the loop it once had."""
    body = step_body()
    start = body.index('$shimsDir = ')
    end = body.index('} else {', start)
    end = body.rindex('\n', start, end) + 1
    return body[:start] + OLD_PATH_BRANCH + body[end:]


def runner_path(github_path_text, original):
    """PATH as the runner builds it: GITHUB_PATH lines, last line first."""
    prepend = []
    for line in github_path_text.splitlines():
        if not line:
            continue
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
        self.shims = str(self.root / 'shims')
        self.tools = [str(self.root / name) for name in ('first', 'second', 'third')]

    def run_step(self, body, entries, shims_dir=None, aliases=()):
        env_ps1 = self.root / 'env.ps1'
        text = '$env:PATH = "' + os.pathsep.join(entries) + os.pathsep + '" + $env:PATH\n'
        for name, target in aliases:
            text += f"Set-Alias -Name {name} -Value '{target}' -Scope Global\n"
        if shims_dir is not None:
            text += '$env:WINDOWS_DIY_SHIMS_DIR = "' + shims_dir + '"\n'
        env_ps1.write_text(text, encoding='utf-8')
        script = self.root / 'step.ps1'
        script.write_text(body, encoding='utf-8')
        github_path = self.root / 'github_path'
        github_env = self.root / 'github_env'
        github_path.write_text('', encoding='utf-8')
        github_env.write_text('', encoding='utf-8')
        env = dict(
            os.environ,
            ENV_PS1_PATH=str(env_ps1),
            GITHUB_PATH=str(github_path),
            GITHUB_ENV=str(github_env),
        )
        env.pop('WINDOWS_DIY_SHIMS_DIR', None)
        command = [self.pwsh, '-NoProfile', '-NonInteractive', '-File', str(script)]
        done = subprocess.run(command, env=env, check=True, capture_output=True, text=True)
        self.output = done.stdout
        original = os.environ['PATH'].split(os.pathsep)
        return runner_path(github_path.read_text(encoding='utf-8'), original), original

    def test_later_steps_see_env_ps1_order(self):
        path, original = self.run_step(step_body(), self.tools)
        self.assertEqual(path[:3], self.tools)
        self.assertEqual(path[3:], original)

    def test_the_shims_directory_goes_behind_the_tools(self):
        # env.ps1 puts its shims first; later steps must find real tools first.
        path, original = self.run_step(
            step_body(), [self.shims] + self.tools, shims_dir=self.shims)
        self.assertEqual(path[:4], self.tools + [self.shims])
        self.assertEqual(path[4:], original)

    def test_a_trailing_separator_still_names_the_shims_directory(self):
        path, _ = self.run_step(
            step_body(), [self.shims] + self.tools, shims_dir=self.shims + os.sep)
        self.assertEqual(path[:4], self.tools + [self.shims])

    def tool_dir(self, name, *files):
        path = self.root / name
        path.mkdir()
        for f in files:
            (path / f).write_text('', encoding='utf-8')
        return str(path)

    def test_each_aliased_tool_comes_from_its_alias_target(self):
        # The run that failed: tup's MSYS2 gcc and GNAT's gcc are on env.ps1's
        # PATH ahead of the WinLibs gcc env.ps1 aliases.
        msys = self.tool_dir('msys', 'gcc.exe', 'make.exe')
        gnat = self.tool_dir('gnat', 'gcc.exe', 'gnatmake.exe')
        winlibs = self.tool_dir('winlibs', 'gcc.exe', 'g++.exe')
        path, original = self.run_step(
            step_body(), [self.shims, msys, gnat, winlibs], shims_dir=self.shims,
            aliases=[
                ('gcc', os.path.join(winlibs, 'gcc.exe')),
                ('gnatmake', os.path.join(gnat, 'gnatmake.exe')),
            ])
        self.assertEqual(path[:4], [winlibs, msys, gnat, self.shims])
        self.assertEqual(path[4:], original)
        self.assertNotIn('::warning::', self.output)

    def test_contradictory_aliases_end_with_a_warning(self):
        a = self.tool_dir('a', 'x.exe', 'y.exe')
        b = self.tool_dir('b', 'x.exe', 'y.exe')
        path, _ = self.run_step(
            step_body(), [a, b],
            aliases=[('x', os.path.join(b, 'x.exe')), ('y', os.path.join(a, 'y.exe'))])
        self.assertEqual(sorted(path[:2]), sorted([a, b]))
        self.assertIn('::warning::setup-dev-env: env.ps1 aliases', self.output)

    def test_the_old_step_reverses_the_order(self):
        # Negative control: the loop the step carried before either rule.
        body = old_step_body()
        self.assertNotIn('$added', body)
        path, _ = self.run_step(body, [self.shims] + self.tools, shims_dir=self.shims)
        self.assertEqual(path[:4], list(reversed([self.shims] + self.tools)))


if __name__ == '__main__':
    unittest.main()
