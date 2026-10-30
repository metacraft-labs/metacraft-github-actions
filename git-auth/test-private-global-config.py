#!/usr/bin/env python3
"""Real Git/HTTP controls for the command-local scoped credential channel.

No process or Git boundary is mocked. The existing smart-HTTP fixture stands
in for a private forge because tests must use a recognizable noncredential,
not contact GitHub with a real secret. Its journal records only auth verdicts.
Default tests require Git, Bash, Python, Cargo and Rust; --repro additionally
tests actual measured Repro materialization and activated Cargo acquisition.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'git-auth/scoped-git-auth.sh'
SERVER = ROOT / 'git-auth/git-http-auth-server.py'
TOKEN = 'ghs_NotARealToken_private_global_config_control_0123456789'
REPRO = None


class PrivateGlobalConfig(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='scoped-global-control-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.scratch = self.base / 'scratch'
        self.scratch.mkdir()
        self.web = self.base / 'web'
        self.web.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'GH_', 'GITHUB_', 'SSH_ASKPASS'))}
        self.env.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                        GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
        seed = self.base / 'seed'
        self.git('init', '-q', str(seed))
        (seed / 'payload').write_text('actual committed source\n')
        self.git('-C', str(seed), 'add', 'payload')
        self.git('-C', str(seed), '-c', 'user.name=Control', '-c',
                  'user.email=control@example.invalid', '-c', 'commit.gpgsign=false',
                  'commit', '-qm', 'seed')
        self.rev = self.git('-C', str(seed), 'rev-parse', 'HEAD').stdout.strip()
        for owner in ('owned', 'outside'):
            target = self.web / owner / 'private.git'
            target.parent.mkdir()
            self.git('clone', '--bare', '-q', str(seed), str(target))
        tokenfile = self.base / 'fixture-token'
        tokenfile.write_text(TOKEN)
        tokenfile.chmod(0o600)
        self.journal = self.base / 'journal'
        self.auth_counts = self.base / 'auth-counts'
        self.auth_counts.write_text('')
        self.server = subprocess.Popen(
            [sys.executable, str(SERVER), '--root', str(self.web), '--journal',
              str(self.journal), '--auth-prefix', '/owned/', '--auth-file', str(tokenfile),
              '--header-count-journal', str(self.auth_counts)],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_server)
        line = self.server.stdout.readline()
        self.assertTrue(line.startswith('PORT '), line)
        self.url = 'http://127.0.0.1:' + line.split()[1] + '/'
        self.trace = self.base / 'child-proof.json'
        self.child = self.base / 'child.py'
        self.child.write_text('''import json,os,stat,subprocess,sys
from pathlib import Path
f=Path(os.environ['GIT_CONFIG_GLOBAL'])
longpaths=subprocess.check_output(['git','config','--bool','--get','core.longpaths'],text=True).strip()
Path(sys.argv[1]).write_text(json.dumps({'config':str(f),'mode':stat.S_IMODE(f.stat().st_mode),'parentMode':stat.S_IMODE(f.parent.stat().st_mode),'argv':sys.argv[2:],'longpaths':longpaths}))
r=subprocess.run(sys.argv[2:]);sys.exit(r.returncode)
''')

    def stop_server(self):
        if self.server.poll() is None:
            self.server.terminate()
        self.server.wait(timeout=10)
        self.server.stdout.close()
        self.server.stderr.close()

    def git(self, *args):
        return subprocess.run(['git', *args], env=self.env, capture_output=True,
                              text=True, check=True, timeout=30)

    def invoke(self, args, *, token=TOKEN, owner='owned'):
        env = dict(self.env, GH_TOKEN=token, TOKEN_OWNERS=owner,
                    GIT_AUTH_URL_BASE=self.url, RUNNER_TEMP=str(self.scratch))
        result = subprocess.run(
            ['bash', '-euo', 'pipefail', '-c', '. "$1"; shift; scoped_git_auth_with_global "$@"',
              'private-global-test', str(LIB), sys.executable, str(self.child),
              str(self.trace), *map(str, args)], env=env, capture_output=True,
            text=True, timeout=60)
        proof = json.loads(self.trace.read_text())
        self.assertEqual(proof['mode'], 0o600)
        self.assertEqual(proof['parentMode'], 0o700)
        self.assertEqual(proof['longpaths'], 'true')
        self.assertFalse(Path(proof['config']).exists())
        self.assertFalse(Path(proof['config']).parent.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])
        for secret in (TOKEN, base64.b64encode(('x-access-token:' + TOKEN).encode()).decode()):
            self.assertNotIn(secret, result.stdout + result.stderr)
            self.assertNotIn(secret, json.dumps(proof))
            for name in self.base.rglob('config'):
                self.assertNotIn(secret, name.read_text(errors='replace'))
        return result

    def test_real_private_clone_and_public_scope(self):
        target = self.base / 'clone'
        r = self.invoke(['git', 'clone', '-q', self.url + 'owned/private.git', target])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((target / 'payload').read_text(), 'actual committed source\n')
        self.assertIn('ok /owned/', self.journal.read_text())
        r = self.invoke(['git', 'clone', '-q', self.url + 'outside/private.git',
                          self.base / 'outside-clone'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('public-noauth /outside/', self.journal.read_text())
        self.assertNotIn('public-auth', self.journal.read_text())

    def test_missing_or_out_of_scope_credential_really_fails(self):
        for token, owner in (('', 'owned'), (TOKEN, 'outside')):
            r = self.invoke(['git', 'clone', '-q', self.url + 'owned/private.git',
                              self.base / ('negative-' + owner + str(bool(token)))],
                            token=token, owner=owner)
            self.assertNotEqual(r.returncode, 0)
        self.assertIn('none /owned/', self.journal.read_text())
        self.assertNotIn('ok /owned/', self.journal.read_text())

    def test_credential_free_ssh_rewrites_keep_owner_scope(self):
        for url, destination in (('git@github.com:owned/private.git', 'ssh-private'),
                                  ('ssh://git@github.com/outside/private.git', 'ssh-public')):
            r = self.invoke(['git', 'clone', '-q', url, self.base / destination])
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((self.base / destination / 'payload').read_text(),
                              'actual committed source\n')
        journal = self.journal.read_text()
        self.assertIn('ok /owned/', journal)
        self.assertIn('public-noauth /outside/', journal)
        self.assertNotIn('public-auth', journal)

    def test_repeated_owner_sends_exactly_one_wire_authorization_header(self):
        r = self.invoke(['git', 'clone', '-q', self.url + 'owned/private.git',
                          self.base / 'repeated-owner'], owner='owned owned')
        self.assertEqual(r.returncode, 0, r.stderr)
        counts = [int(line.split(' ', 1)[0]) for line in self.auth_counts.read_text().splitlines()
                  if '/owned/' in line]
        self.assertTrue(counts, 'the authenticated server received no request')
        self.assertEqual(set(counts), {1})

    def test_failure_cleans_private_file_and_preserves_global_config(self):
        global_config = self.home / '.gitconfig'
        original = '[control]\n\tmarker = preserved\n[core]\n\tlongpaths = false\n'
        global_config.write_text(original)
        r = self.invoke([sys.executable, '-c', 'raise SystemExit(37)'])
        self.assertEqual(r.returncode, 37)
        self.assertEqual(global_config.read_text(), original)

    def test_composite_routes_existing_token_to_the_real_script(self):
        action = (ROOT / 'setup-dev-env/action.yml').read_text()
        block = action.split('id: repro-siblings', 1)[1].split('\n    - name:', 1)[0]
        for binding in ('GH_TOKEN: ${{ inputs.gh-token }}',
                        'TOKEN_OWNERS: ${{ inputs.token-owner }}',
                        'GIT_AUTH_DIR: ${{ github.action_path }}/../git-auth',
                        'SCOPED_GIT_AUTH_MASK: "1"'):
            self.assertIn(binding, block)
        self.assertIn('provision-siblings-from-lock.sh', block)

    def test_reprobuild_routes_existing_job_credential_before_exec(self):
        action = (ROOT / 'setup-dev-env/action.yml').read_text()
        marker = '    - name: Configure Git authentication (reprobuild)\n'
        self.assertIn(marker, action)
        block = action.split(marker, 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("inputs.env-flavor == 'reprobuild'", block)
        self.assertIn("inputs.gh-token != ''", block)
        self.assertIn('GH_TOKEN: ${{ inputs.gh-token }}', block)
        self.assertIn('TOKEN_OWNERS: ${{ inputs.token-owner }}', block)
        self.assertIn('bash "${GITHUB_ACTION_PATH}/../setup-nix/configure-git-auth.sh"', block)
        self.assertLess(action.index(marker), action.index('    - name: Verify Reprobuild development-environment execution'))


class ActualReproMaterialization(PrivateGlobalConfig):
    def provision(self, token, *, ssh=False):
        consumer = self.base / 'consumer'
        consumer.mkdir()
        self.git('init', '-q', str(consumer))
        (consumer / 'repro.lock').write_text(
            'schema = "reprobuild.solved-graph-lock.v3"\n[lock]\n'
            'platform = "amd64-linux"\npackages = []\ndeps = ['
            '{ name = "consumer", self = "true", coord_kind = "vcs", '
            'url = "https://example.invalid/consumer", revision = "' + self.rev + '" }, '
            '{ name = "private", coord_kind = "vcs", url = "' +
            ('git@github.com:owned/private.git' if ssh else self.url + 'owned/private.git') +
            '", revision = "' + self.rev + '" }]\n')
        env = dict(self.env, GH_TOKEN=token, TOKEN_OWNERS='owned',
                    GIT_AUTH_URL_BASE=self.url, RUNNER_TEMP=str(self.scratch),
                    MCL_CONSUMER_ROOT=str(consumer), SIBLING_STRATEGY='repro-lock',
                    GIT_AUTH_DIR=str(ROOT / 'git-auth'),
                    PATH=str(Path(REPRO).parent) + os.pathsep + self.env['PATH'])
        r = subprocess.run(['bash', '-euo', 'pipefail', str(ROOT / 'setup-dev-env/provision-siblings-from-lock.sh')],
                            env=env, cwd=consumer, capture_output=True, text=True, timeout=60)
        for secret in (TOKEN, base64.b64encode(('x-access-token:' + TOKEN).encode()).decode()):
            self.assertNotIn(secret, r.stdout + r.stderr)
        self.assertEqual(list(self.scratch.glob('repro-git-auth.*')), [])
        return r

    def test_actual_repro_private_locked_checkout(self):
        r = self.provision(TOKEN)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.base / 'private/payload').read_text(), 'actual committed source\n')
        self.assertEqual(self.git('-C', str(self.base / 'private'), 'rev-parse', 'HEAD').stdout.strip(), self.rev)
        self.assertIn('ok /owned/', self.journal.read_text())

    def test_actual_repro_without_token_refuses_private_checkout(self):
        r = self.provision('')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.base / 'private/payload').exists())
        self.assertIn('none /owned/', self.journal.read_text())
        self.assertNotIn('ok /owned/', self.journal.read_text())

    def test_actual_repro_private_ssh_locked_checkout(self):
        r = self.provision(TOKEN, ssh=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.base / 'private/payload').read_text(), 'actual committed source\n')
        self.assertIn('ok /owned/', self.journal.read_text())


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

    def fetch(self, name, *, authenticated=False, repro=False):
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
        if authenticated:
            assignments = consumer / 'github-env'
            subprocess.run(
                ['bash', str(ROOT / 'setup-nix/configure-git-auth.sh')],
                env=dict(env, GH_TOKEN=TOKEN, TOKEN_OWNERS='owned',
                          GIT_AUTH_URL_BASE=self.url, GITHUB_ENV=str(assignments)),
                capture_output=True, text=True, check=True, timeout=30)
            # This is the runner's documented GITHUB_ENV boundary, not a Git
            # transport substitute. Never expose the emitted credential bytes.
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
    parser.add_argument('--repro', help='absolute measured Repro CLI for additional real integration')
    args = parser.parse_args()
    if args.repro:
        REPRO = str(Path(args.repro).resolve())
        if not Path(REPRO).is_file() or not os.access(REPRO, os.X_OK):
            parser.error('--repro must name an executable')
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PrivateGlobalConfig)
    suite.addTest(CargoGitAcquisition('test_cargo_requires_and_inherits_job_credential'))
    if REPRO:
        suite.addTest(CargoGitAcquisition('test_actual_repro_cargo_inherits_job_credential'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_private_locked_checkout'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_without_token_refuses_private_checkout'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_private_ssh_locked_checkout'))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
