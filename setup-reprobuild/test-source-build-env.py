"""The Linux/macOS source build hands the engine's pinned sibling sources on.

Property protected: after `Build repro CLI (Linux/macOS)`, every later step of
the job sees each sibling-first source variable the reprobuild dev shell
exported (`SHM_QUEUE_SRC`, `SHM_GSET_SRC`, `CLI_SPEC_SRC`, `ENTRYPOINTS_SRC`,
`CONFUTILS_SRC` -- reprobuild v0.2.35's `SiblingFirstPackageEnvNames`), with
the dev shell's value.

Regression test for codetracer-shell-recorders run 45298400429 (linux-arm64,
reprobuild v0.2.35 built from source because no linux-aarch64 release asset
exists): the build succeeded, then setup-dev-env's `repro exec` failed with
"no acceptable source for SHM_QUEUE_SRC (shm_queue.nim): .../.reprobuild-src
pins 'nim-shm-queue' at 8dff4ad..., there is no checkout of it ..., and
$SHM_QUEUE_SRC is not set". Since reprobuild 8f878684b77 (first released in
v0.2.34) an engine built from a git checkout refuses the tree compiled into
itself for these packages; it takes a sibling checkout at the pin or the tree
the variable names. The step forwarded only NIMCRYPTO_SRC and BEARSSL_SRC.

Stand-ins, and why: `nix` and `just` are replaced by scripts. The real pair
is `nix develop` on reprobuild's flake followed by `just build`, a build of
tens of minutes that needs the private binary cache; neither is what this test
is about. The stand-in `nix` runs the step's own `--command` script, unchanged,
in an environment carrying the variables reprobuild's devShell exports, so the
forwarding code under test is the action's real step body. `runquotad` and the
staged `reprobuild-nix-daemon` are stand-ins for the same reason: the step only
checks that they run.
"""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
STEP = 'Build repro CLI (Linux/macOS)'
SIBLING_FIRST = {
    'SHM_QUEUE_SRC': '/nix/store/aaaa-nim-shm-queue-src/src',
    'SHM_GSET_SRC': '/nix/store/bbbb-nim-shm-gset-src/src',
    'CLI_SPEC_SRC': '/nix/store/cccc-nim-cli-spec-src/src',
    'ENTRYPOINTS_SRC': '/nix/store/dddd-nim-entrypoints-src/src',
    'CONFUTILS_SRC': '/nix/store/eeee-nim-confutils-src',
}


def step_body(name):
    lines = (HERE / 'action.yml').read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    run = lines.index('      run: |', start, end)
    return '\n'.join(line[8:] if line.startswith('        ') else ''
                    for line in lines[run + 1:end]) + '\n'


def executable(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SourceBuildEnvironment(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='repro-source-env-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / 'workspace'
        helper = self.workspace / '.reprobuild-src' / 'build' / 'bin' / 'reprobuild-nix-daemon'
        helper.parent.mkdir(parents=True)
        executable(helper, '#!/bin/sh\nexit 0\n')
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        # `nix develop ... --command bash -c <script>`: run what follows
        # `--command` in the dev-shell environment named by DEV_SHELL_ENV.
        executable(self.tools / 'nix', '\n'.join([
            '#!/usr/bin/env bash',
            'set -euo pipefail',
            'while [ "$#" -gt 0 ] && [ "$1" != --command ]; do shift; done',
            '[ "$#" -gt 0 ] || { echo "stand-in nix: no --command" >&2; exit 2; }',
            'shift',
            'set -a; . "${DEV_SHELL_ENV}"; set +a',
            'exec "$@"',
        ]) + '\n')
        executable(self.tools / 'just', '#!/bin/sh\n[ "$1" = build ]\n')
        executable(self.tools / 'runquotad', '#!/bin/sh\necho "runquotad stand-in"\n')
        for tool in ('bash', 'python3', 'cat', 'uname', 'test'):
            found = shutil.which(tool)
            self.assertIsNotNone(found, 'the suite needs ' + tool)
            if not (self.tools / tool).exists():
                (self.tools / tool).symlink_to(found)
        self.github_env = self.root / 'github-env'
        self.github_path = self.root / 'github-path'

    def run_step(self, dev_shell, extra_env=None):
        dev_shell_env = self.root / 'dev-shell.env'
        dev_shell_env.write_text(''.join(
            "{}='{}'\n".format(name, value) for name, value in dev_shell.items()))
        env = {
            'PATH': str(self.tools),
            'HOME': str(self.root),
            'RUNNER_TEMP': str(self.root),
            'GITHUB_ENV': str(self.github_env),
            'GITHUB_PATH': str(self.github_path),
            'MCL_WORKSPACE_ROOT': str(self.workspace),
            'MCL_LEGACY_LAYOUT': 'false',
            'IO_MON_PIN': '',
            'DEV_SHELL_ENV': str(dev_shell_env),
        }
        env.update(extra_env or {})
        result = subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail',
                                  '-c', step_body(STEP)],
                                cwd=self.root, env=env, text=True,
                                capture_output=True, timeout=60)
        exported = {}
        if self.github_env.exists():
            for line in self.github_env.read_text().splitlines():
                name, _, value = line.partition('=')
                exported[name] = value
        return result, exported

    def test_every_sibling_first_source_reaches_later_steps(self):
        dev_shell = dict(SIBLING_FIRST, NIMCRYPTO_SRC='/nix/store/ffff-nimcrypto',
                          BEARSSL_SRC='/nix/store/gggg-nim-bearssl')
        result, exported = self.run_step(dev_shell)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name, value in SIBLING_FIRST.items():
            self.assertEqual(exported.get(name), value,
                              name + ' was not forwarded:\n' + self.github_env.read_text())
        self.assertEqual(exported.get('NIMCRYPTO_SRC'), '/nix/store/ffff-nimcrypto')
        self.assertEqual(exported.get('BEARSSL_SRC'), '/nix/store/gggg-nim-bearssl')

    def test_a_dev_shell_without_them_forwards_none_and_still_succeeds(self):
        # An older reprobuild (a repro-build-pin before these inputs existed)
        # neither exports nor reads them; an empty assignment is not forwarded.
        dev_shell = dict(NIMCRYPTO_SRC='/nix/store/ffff-nimcrypto',
                          BEARSSL_SRC='/nix/store/gggg-nim-bearssl', CLI_SPEC_SRC='')
        result, exported = self.run_step(dev_shell)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in SIBLING_FIRST:
            self.assertNotIn(name, exported, self.github_env.read_text())

    def test_the_required_sources_are_still_required(self):
        result, _ = self.run_step(dict(SIBLING_FIRST, BEARSSL_SRC='/nix/store/gggg'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reprobuild dev shell did not set NIMCRYPTO_SRC', result.stderr)


if __name__ == '__main__':
    unittest.main()
