#!/usr/bin/env python3
"""Real private Cargo/Git acquisition through the shared credential channel.

The existing loopback smart-HTTP fixture stands in for a private forge using
only a recognizable synthetic noncredential. Git, Cargo and optional selected
Repro are real processes; no acquisition/activation boundary is mocked. Each
arm starts with a cold Cargo home and verifies the exact committed checkout.
Default runs the direct Cargo control; --repro additionally requires actual
recipe activation. Explicit unavailable --repro fails, never skips.
"""
from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
fixture = runpy.run_path(str(ROOT / 'git-auth/test-private-global-config.py'),
                        run_name='private_git_fixture')
PrivateGlobalConfig = fixture['PrivateGlobalConfig']
TOKEN = fixture['TOKEN']
REPRO = None
ACTION = ROOT / 'setup-dev-env/action.yml'


class CargoGitAcquisition(PrivateGlobalConfig):
    """Real Cargo/Git acquisition, with a cold Cargo home for every arm."""

    def setUp(self):
        super().setUp()
        seed = self.base / 'seed'
        (seed / 'src').mkdir()
        (seed / 'Cargo.toml').write_text(
            '[package]\nname="private-control"\nversion="0.1.0"\nedition="2021"\n')
        (seed / 'src/lib.rs').write_text('pub const WITNESS: u32 = 37;\n')
        self.git('-C', str(seed), 'add', '.')
        self.git('-C', str(seed), '-c', 'user.name=Control', '-c',
                  'user.email=control@example.invalid', '-c', 'commit.gpgsign=false',
                  'commit', '-qm', 'real crate')
        self.rev = self.git('-C', str(seed), 'rev-parse', 'HEAD').stdout.strip()
        self.git('-C', str(seed), 'push', '-q', str(self.web / 'owned/private.git'), 'HEAD:master')

    def fetch(self, name, *, authenticated=False, repro=False, flavor='reprobuild'):
        consumer = self.base / name
        consumer.mkdir()
        (consumer / 'src').mkdir()
        (consumer / 'src/lib.rs').write_text('pub fn consumer() {}\n')
        (consumer / 'Cargo.toml').write_text(
            '[package]\nname="consumer"\nversion="0.1.0"\nedition="2021"\n'
            '[dependencies]\nprivate-control={git="' + self.url +
            'owned/private.git",rev="' + self.rev + '"}\n')
        cargo_home = consumer / 'cargo-home'
        env = dict(self.env, CARGO_HOME=str(cargo_home),
                    CARGO_NET_GIT_FETCH_WITH_CLI='true', CARGO_NET_RETRY='0')
        assignments = consumer / 'github-env'
        assignments.touch(mode=0o600)
        # Reuse the owning reader and the existing fixtures' named-step
        # extraction convention. Only this known input binding is interpreted;
        # this is not a general composite-action runner. The actual run body,
        # including its helper selection, executes unchanged in real Bash.
        action = subprocess.check_output(
            ['node', str(ROOT / '.github/read-workflow.cjs'), str(ACTION)], text=True)
        marker = '    - name: Configure Git authentication (reprobuild)\n'
        if marker in action:
            step = action.split(marker, 1)[1].split('\n    - name:', 1)[0]
            self.assertIn("if: ${{ inputs.env-flavor == 'reprobuild' && inputs.gh-token != '' }}", step)
            self.assertIn('GH_TOKEN: ${{ inputs.gh-token }}', step)
            self.assertIn('TOKEN_OWNERS: ${{ inputs.token-owner }}', step)
        else:
            # Exact pre-fix source performs no such setup. Its positive arm
            # must consequently fail at the real authenticated Git boundary.
            step = None
        if step is not None and authenticated and flavor == 'reprobuild':
            body = step.split('      run: ', 1)[1].strip()
            self.assertNotEqual(body, '|', 'use the existing block extractor if this step grows')
            subprocess.run(
                ['bash', '-euo', 'pipefail', '-c', body],
                env=dict(env, GH_TOKEN=TOKEN, TOKEN_OWNERS='owned',
                          GIT_AUTH_URL_BASE=self.url, GITHUB_ENV=str(assignments),
                          GITHUB_ACTION_PATH=str(ROOT / 'setup-dev-env')),
                capture_output=True, text=True, check=True, timeout=30)
        # Replay only the documented GITHUB_ENV handoff, never a transport.
        # Never expose the emitted credential bytes.
        for line in assignments.read_text().splitlines():
            key, value = line.split('=', 1)
            env[key] = value
        assignments.unlink()
        command = ['cargo', 'fetch', '--manifest-path', str(consumer / 'Cargo.toml')]
        if repro:
            project = self.base / 'activation-project'
            project.mkdir(exist_ok=True)
            (project / 'repro.nim').write_text(
                'import repro_project_dsl\npackage authFixture:\n'
                '  devEnv:\n    setEnv "GHA_AUTH_FIXTURE", "active"\n')
            command = [REPRO, 'exec', str(project), '--', sys.executable, '-c',
                        'import os,sys; assert os.environ.get("GHA_AUTH_FIXTURE") == "active"; '
                        'os.execvp(sys.argv[1], sys.argv[1:])', *command]
        # As in the owning wrapper fixture, Repro can start a service which
        # inherits its output handles. Files observe the command's completion;
        # pipes would wait for the unrelated lifetime of the inherited handle.
        with (consumer / 'stdout').open('w') as output, (consumer / 'stderr').open('w') as error:
            result = subprocess.run(command, cwd=consumer, env=env, stdout=output,
                                    stderr=error, text=True, timeout=600)
        result.stdout = (consumer / 'stdout').read_text()
        result.stderr = (consumer / 'stderr').read_text()
        for secret in (TOKEN, base64.b64encode(('x-access-token:' + TOKEN).encode()).decode()):
            self.assertNotIn(secret, result.stdout + result.stderr)
            for config in cargo_home.rglob('config'):
                self.assertNotIn(secret, config.read_text(errors='replace'))
        if result.returncode == 0:
            witnesses = list((cargo_home / 'git/checkouts').rglob('payload'))
            self.assertEqual(len(witnesses), 1)
            self.assertEqual(witnesses[0].read_text(), 'actual committed source\n')
            self.assertEqual(self.git('-C', str(witnesses[0].parent), 'rev-parse', 'HEAD').stdout.strip(), self.rev)
            self.assertIn('ok /owned/', self.journal.read_text())
        return result

    def test_cargo_requires_and_inherits_job_credential(self):
        negative = self.fetch('without-job-auth')
        self.assertNotEqual(negative.returncode, 0)
        self.assertIn('none /owned/', self.journal.read_text())
        wrong_flavor = self.fetch('different-flavor', authenticated=True, flavor='nix')
        self.assertNotEqual(wrong_flavor.returncode, 0)
        self.assertNotIn('ok /owned/', self.journal.read_text())
        positive = self.fetch('with-job-auth', authenticated=True)
        self.assertEqual(positive.returncode, 0, positive.stdout + positive.stderr)

    def test_actual_repro_cargo_inherits_job_credential(self):
        negative = self.fetch('repro-without-job-auth', repro=True)
        self.assertNotEqual(negative.returncode, 0)
        self.assertIn('none /owned/', self.journal.read_text(), negative.stdout + negative.stderr)
        positive = self.fetch('repro-with-job-auth', authenticated=True, repro=True)
        self.assertEqual(positive.returncode, 0, positive.stdout + positive.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repro', help='absolute measured Repro CLI for real activation')
    parser.add_argument('--action-yml', type=Path, default=ACTION,
                        help='exact action source for old/new regression controls')
    args = parser.parse_args()
    ACTION = args.action_yml.resolve(strict=True)
    if args.repro:
        REPRO = str(Path(args.repro).resolve())
        if not Path(REPRO).is_file() or not os.access(REPRO, os.X_OK):
            parser.error('--repro must name an executable')
    suite = unittest.TestSuite([
        CargoGitAcquisition('test_cargo_requires_and_inherits_job_credential')])
    if REPRO:
        suite.addTest(CargoGitAcquisition('test_actual_repro_cargo_inherits_job_credential'))
    expected = 2 if REPRO else 1
    assert suite.countTestCases() == expected
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
