#!/usr/bin/env python3
"""Real Git/HTTP controls for the command-local scoped credential channel.

No process or Git boundary is mocked. The existing smart-HTTP fixture stands
in for a private forge because tests must use a recognizable noncredential,
not contact GitHub with a real secret. Its journal records only auth verdicts.
Default tests require Git, Bash and Python; --repro additionally tests actual
measured Repro materialization. Cargo acquisition has its own portable suite.

The git-auth composite action (git-auth/action.yml) is driven through its real
`run:` body and `env:` bindings, extracted from the manifest text, exactly as
the runner would execute them. The --repro cases include the negative control
for the defect the action exists for: the same `repro develop` invocation, with
the credential only in numbered GIT_CONFIG_* configuration (what setup-nix
exports job-wide), must fail to clone the private repository even though plain
`git ls-remote` with that configuration succeeds.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'git-auth/scoped-git-auth.sh'
SERVER = ROOT / 'git-auth/git-http-auth-server.py'
ACTION = ROOT / 'git-auth/action.yml'
TOKEN = 'ghs_NotARealToken_private_global_config_control_0123456789'
BLOB = base64.b64encode(('x-access-token:' + TOKEN).encode()).decode()
REPRO = None
ACTION_STEP_MARKER = '    - name: Run with the scoped Git credential\n'


def action_step():
    """Return (bindings, working_directory, body) of git-auth/action.yml's step.

    Plain text parsing, like the other composite tests here: no YAML library
    is assumed on the runner. The manifest is laid out with a fixed indent, so
    a change that moves these keys fails here rather than testing something
    other than what GitHub runs.
    """
    text = ACTION.read_text()
    assert ACTION_STEP_MARKER in text, 'git-auth/action.yml lost its step'
    step = text.split(ACTION_STEP_MARKER, 1)[1]
    head, body_text = step.split('      run: |\n', 1)
    workdir = None
    bindings = {}
    in_env = False
    for line in head.splitlines():
        stripped = line.strip()
        if line.startswith('      working-directory: '):
            workdir = line.split(': ', 1)[1]
        if line == '      env:':
            in_env = True
            continue
        if in_env:
            if not line.startswith('        '):
                in_env = False
                continue
            if stripped.startswith('#'):
                continue
            name, value = stripped.split(': ', 1)
            bindings[name] = value
    body = []
    for line in body_text.splitlines():
        if line and not line.startswith('        '):
            break
        body.append(line[8:])
    return bindings, workdir, '\n'.join(body).rstrip('\n') + '\n'


def resolve(expression, inputs):
    """Evaluate the only expression shapes the step uses: an input or a literal."""
    if expression.startswith('${{ inputs.') and expression.endswith(' }}'):
        return inputs[expression[len('${{ inputs.'):-len(' }}')]]
    assert '${{' not in expression, 'unsupported expression ' + expression
    return expression.strip('"')


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
        tokenfile = self.tokenfile = self.base / 'fixture-token'
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
Path(sys.argv[1]).write_text(json.dumps({'config':str(f),'mode':stat.S_IMODE(f.stat().st_mode),'parentMode':stat.S_IMODE(f.parent.stat().st_mode),'argv':sys.argv[2:],'longpaths':longpaths,'ghToken':'GH_TOKEN' in os.environ,'numbered':sorted(k for k in os.environ if k.startswith(('GIT_CONFIG_COUNT','GIT_CONFIG_KEY_','GIT_CONFIG_VALUE_')))}))
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

    # ---- git-auth/action.yml, the composite consumers call -----------------

    def job_numbered_credential(self):
        """The job-wide credential setup-nix's configure-git-auth.sh exports.

        Every consuming job carries it, so the action is exercised with it in
        the environment: the script must still take its credential from the
        private file, not from this.
        """
        return {'GIT_CONFIG_COUNT': '1',
                'GIT_CONFIG_KEY_0': 'http.' + self.url + 'owned/.extraHeader',
                'GIT_CONFIG_VALUE_0': 'AUTHORIZATION: basic ' + BLOB}

    def assert_no_credential_leak(self, result):
        output = result.stdout + result.stderr
        self.assertNotIn(TOKEN, output)
        # The derived header may appear only as the payload of the runner's
        # `::add-mask::` command, which the runner consumes and never logs.
        for line in output.splitlines():
            if BLOB in line:
                self.assertTrue(line.startswith('::add-mask::'), 'credential printed: ' + line[:40])
        self.assertEqual(list(self.scratch.iterdir()), [], 'private config left in RUNNER_TEMP')
        for path in self.base.rglob('*'):
            if path == self.tokenfile or path.is_symlink() or not path.is_file():
                continue
            data = path.read_bytes()
            self.assertNotIn(TOKEN.encode(), data, path)
            self.assertNotIn(BLOB.encode(), data, path)

    def run_action(self, script, *, token=TOKEN, owner='owned', workdir=None, job_env=None):
        """Execute the action's real run: body with its real env: bindings."""
        bindings, workdir_expr, body = action_step()
        inputs = {'gh-token': token, 'token-owner': owner,
                  'working-directory': str(workdir or self.base), 'run': script}
        step_env = {name: resolve(value, inputs) for name, value in bindings.items()}
        script_file = self.base / 'action-step.sh'
        script_file.write_text(body)
        env = dict(self.env, GITHUB_ACTION_PATH=str(ROOT / 'git-auth'),
                   RUNNER_TEMP=str(self.scratch), GIT_AUTH_URL_BASE=self.url)
        env.update(job_env or {})
        env.update(step_env)
        # How the runner executes a `shell: bash` step.
        result = subprocess.run(['bash', '--noprofile', '--norc', '-eo', 'pipefail', str(script_file)],
                                env=env, cwd=resolve(workdir_expr, inputs),
                                capture_output=True, text=True, timeout=120)
        self.assert_no_credential_leak(result)
        return result

    def test_action_binding_contract(self):
        bindings, workdir, body = action_step()
        self.assertEqual(bindings, {'GH_TOKEN': '${{ inputs.gh-token }}',
                                    'TOKEN_OWNERS': '${{ inputs.token-owner }}',
                                    'GIT_AUTH_RUN': '${{ inputs.run }}',
                                    'SCOPED_GIT_AUTH_MASK': '"1"'})
        self.assertEqual(workdir, '${{ inputs.working-directory }}')
        # Inputs reach the script only through the environment; an expression
        # in the body would splice caller text into shell source.
        self.assertNotIn('${{', body)
        self.assertIn('. "${GITHUB_ACTION_PATH}/scoped-git-auth.sh"', body)
        self.assertIn('scoped_git_auth_with_global', body)
        self.assertIn('export -n GH_TOKEN', body)
        manifest = ACTION.read_text().split('\nruns:\n', 1)[0]
        for declaration in ('  gh-token:\n', '  token-owner:\n', '  working-directory:\n', '  run:\n'):
            self.assertIn(declaration, manifest)
        self.assertIn('    default: metacraft-labs\n', manifest)
        self.assertIn('    default: "."\n', manifest)

    def test_action_private_clone_through_private_global_config(self):
        workdir = self.base / 'work'
        workdir.mkdir()
        target = self.base / 'action-clone'
        script = ('pwd > ' + shlex.quote(str(self.base / 'action-pwd')) + '\n' +
                  shlex.join([sys.executable, str(self.child), str(self.trace), 'git', 'clone', '-q',
                              self.url + 'owned/private.git', str(target)]) + '\n')
        r = self.run_action(script, workdir=workdir, job_env=self.job_numbered_credential())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((target / 'payload').read_text(), 'actual committed source\n')
        self.assertIn('ok /owned/', self.journal.read_text())
        self.assertEqual((self.base / 'action-pwd').read_text().strip(), str(workdir))
        self.assertIn('::add-mask::' + BLOB, r.stdout)
        proof = json.loads(self.trace.read_text())
        self.assertEqual(proof['mode'], 0o600)
        self.assertEqual(proof['parentMode'], 0o700)
        self.assertFalse(Path(proof['config']).exists())
        self.assertFalse(Path(proof['config']).parent.exists())
        self.assertFalse(proof['ghToken'], 'GH_TOKEN was exported to the script')
        self.assertEqual(proof['numbered'], [], 'job-wide numbered config reached the script')

    def test_action_empty_token_refuses_before_running(self):
        marker = self.base / 'ran'
        # The job credential is present, so a silent fallback would succeed.
        r = self.run_action('touch ' + shlex.quote(str(marker)), token='',
                            job_env=self.job_numbered_credential())
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('gh-token input is empty', r.stderr)
        self.assertFalse(marker.exists())
        self.assertNotIn('/owned/', self.journal.read_text() if self.journal.exists() else '')

    def test_action_script_runs_errexit_and_keeps_status(self):
        marker = self.base / 'after-false'
        r = self.run_action('false\ntouch ' + shlex.quote(str(marker)))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(marker.exists())
        r = self.run_action('exit 37')
        self.assertEqual(r.returncode, 37)


class ActualReproMaterialization(PrivateGlobalConfig):
    def consumer(self, *, ssh=False):
        """A consumer checkout whose committed lock pins one private sibling."""
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
        return consumer

    def repro_path(self):
        return str(Path(REPRO).parent) + os.pathsep + self.env['PATH']

    def develop_command(self):
        # The invocation codetracer's provision-repro-lock-siblings runs.
        return ['repro', 'develop', '--all', '--only=private', '--reset', '--into=' + str(self.base)]

    def test_actual_repro_develop_through_git_auth_action(self):
        consumer = self.consumer()
        job_env = dict(self.job_numbered_credential(), PATH=self.repro_path())
        r = self.run_action(shlex.join(self.develop_command()) + '\n', workdir=consumer, job_env=job_env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.base / 'private/payload').read_text(), 'actual committed source\n')
        self.assertEqual(self.git('-C', str(self.base / 'private'), 'rev-parse', 'HEAD').stdout.strip(), self.rev)
        self.assertIn('ok /owned/', self.journal.read_text())

    def test_actual_repro_develop_ignores_numbered_job_credential(self):
        """Negative control: the defect the git-auth action exists for.

        The job-wide numbered configuration is a valid credential (plain git
        authenticates with it below), yet Repro scrubs it before its own clone,
        so the private sibling is not materialized.
        """
        consumer = self.consumer()
        env = dict(self.env, GIT_CONFIG_GLOBAL=os.devnull, PATH=self.repro_path(),
                   **self.job_numbered_credential())
        probe = subprocess.run(['git', 'ls-remote', self.url + 'owned/private.git', 'HEAD'],
                               env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertIn(self.rev, probe.stdout)
        self.assertIn('ok /owned/', self.journal.read_text())
        before = len(self.journal.read_text())
        r = subprocess.run(self.develop_command(), env=env, cwd=consumer,
                           capture_output=True, text=True, timeout=120)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.base / 'private/payload').exists())
        attempt = self.journal.read_text()[before:]
        self.assertIn('none /owned/', attempt)
        self.assertNotIn('ok /owned/', attempt)

    def provision(self, token, *, ssh=False):
        consumer = self.consumer(ssh=ssh)
        env = dict(self.env, GH_TOKEN=token, TOKEN_OWNERS='owned',
                    GIT_AUTH_URL_BASE=self.url, RUNNER_TEMP=str(self.scratch),
                    MCL_CONSUMER_ROOT=str(consumer), SIBLING_STRATEGY='repro-lock',
                    GIT_AUTH_DIR=str(ROOT / 'git-auth'),
                    PATH=self.repro_path())
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
        suite.addTest(ActualReproMaterialization('test_actual_repro_develop_through_git_auth_action'))
        suite.addTest(ActualReproMaterialization('test_actual_repro_develop_ignores_numbered_job_credential'))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
