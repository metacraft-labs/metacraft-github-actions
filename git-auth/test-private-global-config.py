#!/usr/bin/env python3
"""Real Git/HTTP controls for the command-local scoped credential channel.

No process or Git boundary is mocked. The existing smart-HTTP fixture stands
in for a private forge because tests must use a recognizable noncredential,
not contact GitHub with a real secret. Its journal records only auth verdicts.
Default tests require Git, Bash and Python; --repro adds an actual measured
Repro materialization control without pretending CI has built that SDK.
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
        self.server = subprocess.Popen(
            [sys.executable, str(SERVER), '--root', str(self.web), '--journal',
              str(self.journal), '--auth-prefix', '/owned/', '--auth-file', str(tokenfile)],
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


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repro', help='absolute measured Repro CLI for additional real integration')
    args = parser.parse_args()
    if args.repro:
        REPRO = str(Path(args.repro).resolve())
        if not Path(REPRO).is_file() or not os.access(REPRO, os.X_OK):
            parser.error('--repro must name an executable')
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PrivateGlobalConfig)
    if REPRO:
        suite.addTest(ActualReproMaterialization('test_actual_repro_private_locked_checkout'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_without_token_refuses_private_checkout'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_private_ssh_locked_checkout'))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
