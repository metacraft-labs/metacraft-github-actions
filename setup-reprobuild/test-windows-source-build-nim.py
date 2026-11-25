"""The Windows source build leaves the engine's Nim choice to the engine.

Property protected: after `Build repro CLI (Windows)`, no later step of the
job sees a `REPRO_NIM_COMPILER` in `$GITHUB_ENV`, whether it would come from
the `nim.exe` env.ps1 put on PATH or from a variable env.ps1 set.

Regression test for codetracer-move-recorder PR #19 (windows-x64, Reprobuild
built from source at the fleet pin). The step exported the `nim.exe` that
reprobuild's env.ps1 provisions, the stock Nim 2.2.8 that builds repro
itself, as `REPRO_NIM_COMPILER`. The engine keeps a caller-set
`REPRO_NIM_COMPILER` as an explicit choice, and its provider compile passes
`--compilerArgsFile` because a Windows command line is capped at 32,767
characters. The stock Nim refused it: `command line(1, 2) Error: invalid
command line option: '--compilerArgsFile'`. With the variable unset, the
engine provisions its own Nim build, which accepts the option, as it already
did for release installs.

How: the step's real body runs under pwsh. A negative control puts back the
export the step used to carry, and another drops the variable from the
env.ps1-delta exclusion list. Both must make the check fail, so a harness that
stopped reaching the export code cannot pass. A positive control requires the
`REPRO_BOOTSTRAP_CC` export the same lookup produces, so `Get-Command` really
found the stand-in compilers.

Stand-ins, and why: env.ps1, `just`, `build-runquota-bootstrap.ps1` and
`windows/stage-release-dlls.ps1` are replaced by small scripts. The real ones
download and install a Windows toolchain, build RunQuota and build repro: an
hour of work that only runs on Windows, and none of it decides what the step
writes to `$GITHUB_ENV`. The stand-in env.ps1 does what the real one does that
matters here: it puts a directory holding `nim.exe` and `gcc.exe` first on
PATH and sets a variable of its own. The compilers are never started, only
found. This lets the check run on Linux as well as on Windows, where the CI
job runs it too.
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ACTION = HERE / 'action.yml'
STEP = 'Build repro CLI (Windows)'
WINDOWS = os.name == 'nt'
ANCHOR = '$gccCmd = Get-Command gcc.exe -ErrorAction SilentlyContinue\n'

# The export the step carried from f0aceed (2026-09-17) until this fix.
OLD_NIM_EXPORT = '''\
$nimCmd = Get-Command nim.exe -ErrorAction SilentlyContinue
if ($nimCmd) {
  Add-Content -Path $env:GITHUB_ENV -Value "REPRO_NIM_COMPILER=$($nimCmd.Source)"
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


def body_with_old_export():
    body = step_body()
    assert body.count(ANCHOR) == 1, 'the gcc export moved; update ANCHOR'
    return body.replace(ANCHOR, OLD_NIM_EXPORT + ANCHOR)


def body_without_exclusion():
    body = step_body()
    excluded = '"REPRO_NIM_COMPILER", '
    assert body.count(excluded) == 1, 'the exclusion list moved; update the control'
    return body.replace(excluded, '')


def exported(github_env):
    """`$GITHUB_ENV` as name -> value. The step writes only NAME=VALUE lines."""
    result = {}
    for line in github_env.read_text(encoding='utf-8').splitlines():
        if line:
            name, _, value = line.partition('=')
            result[name.upper() if WINDOWS else name] = value
    return result


def executable(path, text):
    path.write_text(text, encoding='utf-8')
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class WindowsSourceBuildNim(unittest.TestCase):
    def setUp(self):
        self.pwsh = shutil.which('pwsh')
        if self.pwsh is None:
            self.fail('pwsh is not on PATH; this test runs the real step')
        temporary = tempfile.TemporaryDirectory(prefix='windows-source-build-nim-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / 'workspace'
        source = self.workspace / '.reprobuild-src'
        (source / 'build' / 'bin').mkdir(parents=True)
        (source / 'windows').mkdir()
        (source / 'windows' / 'stage-release-dlls.ps1').write_text('', encoding='utf-8')
        self.toolchain = self.root / 'toolchain'
        self.toolchain.mkdir()
        # Found by Get-Command, never started.
        for name in ('nim.exe', 'gcc.exe'):
            executable(self.toolchain / name, '#!/bin/sh\nexit 99\n')
        # `just build`: a script on POSIX, a batch file on Windows.
        executable(self.toolchain / 'just', '#!/bin/sh\n[ "$1" = build ]\n')
        (self.toolchain / 'just.cmd').write_text(
            '@if "%1"=="build" (exit /b 0) else (exit /b 2)\r\n', encoding='utf-8')
        self.action_path = self.root / 'action'
        self.action_path.mkdir()
        (self.action_path / 'build-runquota-bootstrap.ps1').write_text('', encoding='utf-8')
        self.env_ps1 = source / 'env.ps1'
        self.github_env = self.root / 'github_env'
        self.github_path = self.root / 'github_path'

    def run_step(self, body, env_ps1_sets_nim=False, extra_env=None):
        text = ('$env:PATH = "' + str(self.toolchain) + '" + '
                '[IO.Path]::PathSeparator + $env:PATH\n'
                '$env:BEARSSL_SRC = "' + str(self.root / 'bearssl') + '"\n')
        if env_ps1_sets_nim:
            text += '$env:REPRO_NIM_COMPILER = "' + str(self.toolchain / 'nim.exe') + '"\n'
        self.env_ps1.write_text(text, encoding='utf-8')
        script = self.root / 'step.ps1'
        script.write_text(body, encoding='utf-8')
        self.github_env.write_text('', encoding='utf-8')
        self.github_path.write_text('', encoding='utf-8')
        env = dict(
            os.environ,
            GITHUB_ENV=str(self.github_env),
            GITHUB_PATH=str(self.github_path),
            GITHUB_ACTION_PATH=str(self.action_path),
            MCL_WORKSPACE_ROOT=str(self.workspace),
            MCL_LEGACY_LAYOUT='false',
            REPROBUILD_BUILD_MODE='release',
        )
        env.update(extra_env or {})
        for name in [n for n in env if n.upper() in ('REPRO_NIM_COMPILER', 'REPRO_BOOTSTRAP_CC')]:
            del env[name]
        command = [self.pwsh, '-NoProfile', '-NonInteractive', '-File', str(script)]
        done = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return exported(self.github_env)

    def assert_names(self, env, name, tool):
        # samefile, not string equality: on a Windows runner the temporary
        # directory may be spelled with an 8.3 short name on one side only.
        self.assertIn(name, env)
        self.assertTrue(os.path.samefile(env[name], self.toolchain / tool), env)

    def assert_reached_the_exports(self, env):
        # Positive control: the same Get-Command lookup found the stand-in
        # gcc.exe, and the env.ps1 delta loop ran.
        self.assert_names(env, 'REPRO_BOOTSTRAP_CC', 'gcc.exe')
        self.assertEqual(env.get('BEARSSL_SRC'), str(self.root / 'bearssl'), env)

    def test_later_steps_get_no_nim_compiler(self):
        env = self.run_step(step_body())
        self.assert_reached_the_exports(env)
        self.assertNotIn('REPRO_NIM_COMPILER', env)

    def test_a_nim_compiler_env_ps1_sets_is_not_forwarded(self):
        env = self.run_step(step_body(), env_ps1_sets_nim=True)
        self.assert_reached_the_exports(env)
        self.assertNotIn('REPRO_NIM_COMPILER', env)

    def test_the_old_export_is_caught(self):
        # Negative control: the export f0aceed added, put back.
        env = self.run_step(body_with_old_export())
        self.assert_reached_the_exports(env)
        self.assert_names(env, 'REPRO_NIM_COMPILER', 'nim.exe')

    def test_a_forwarded_env_ps1_value_is_caught(self):
        # Negative control: without the exclusion, the delta loop forwards it.
        env = self.run_step(body_without_exclusion(), env_ps1_sets_nim=True)
        self.assert_names(env, 'REPRO_NIM_COMPILER', 'nim.exe')


if __name__ == '__main__':
    unittest.main()
