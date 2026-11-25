"""A job can keep setup-dev-env's Git credential and build environment out of
its later steps.

Two opt-outs, both off by default:

- `git-access: none`. setup-dev-env still authenticates its own sibling
  clones, which never reach the job environment, but installs no job-scoped
  Git credential. Later steps start with no `GIT_CONFIG_*` from this action
  and no token file. setup-dev-env records the declaration in the job's
  credential directory before anything installs a credential.
  git-auth/scoped-git-auth.sh then makes every installer write nothing: the
  setup-nix runs, this action's own Git authentication step, and
  refresh-build-auth. A last step fails the action if the job's Git
  configuration changed anyway, so an installer that ignores the declaration
  (an older setup-nix) is caught, not trusted.
- `export-build-env: false`, forwarded to setup-reprobuild. A source build's
  environment then goes to the files setup-reprobuild's `build-env-dir` names
  instead of to the job. This action's own `repro exec` check loads it from
  there, so the CLI is still verified with the environment it was built for.

Why: nim-libvterm's native Windows ARM64 leg refuses inherited Git runtime
configuration before its own checkout, and refuses an inherited RunQuota or
toolchain before building RunQuota natively. setup-dev-env exported both.

How: the steps' real bodies and scripts run under bash with a temporary
RUNNER_TEMP, GITHUB_ENV and GITHUB_OUTPUT, and their output files are read
back. The `repro exec` check runs against a stand-in `repro`. It is a short
script that runs its command only when the loaded build environment is
present. The real CLI is not what this checks: the property is which
environment the step hands it. The end-to-end case then runs the real
setup-nix/configure-git-auth.sh under the job environment the recording step
produced.
"""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ACTION = HERE / 'action.yml'
WINDOWS = os.name == 'nt'

VALIDATE = 'Validate env-flavor'
RECORD = 'Record the job\'s Git access'
CHECK = 'Check that the job\'s Git configuration is untouched'
VERIFY = 'Verify Reprobuild development-environment execution'
CONFIGURE = 'Configure Git authentication (reprobuild)'
INSTALL = 'Install the repro CLI (reprobuild)'
GIT_KEYS = ('GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS')


def action_text():
    return ACTION.read_text(encoding='utf-8')


def step(name):
    marker = '    - name: ' + name + '\n'
    text = action_text()
    if marker not in text:
        raise AssertionError('action.yml has no step named ' + repr(name))
    return text.split(marker, 1)[1].split('\n    - name: ', 1)[0]


def step_body(name, substitutions=()):
    body = step(name).split('      run: |\n', 1)[1]
    text = '\n'.join(line[8:] if line.startswith('        ') else line
        for line in body.splitlines()) + '\n'
    for old, new in substitutions:
        text = text.replace(old, new)
    return text


def step_script(name):
    """The script a one-line `run: bash "${GITHUB_ACTION_PATH}/x.sh"` names."""
    run = step(name).split('      run: ', 1)[1].splitlines()[0]
    prefix = 'bash "${GITHUB_ACTION_PATH}/'
    if not run.startswith(prefix):
        raise AssertionError(name + ' does not run a script: ' + run)
    return HERE / run[len(prefix):].rstrip('"')


def read_env(path):
    result = {}
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            if line:
                name, _, value = line.partition('=')
                result[name] = value
    return result


def clean_environment(**extra):
    env = {name: value for name, value in os.environ.items()
        if not name.startswith('GIT_CONFIG') and name != 'MCL_JOB_CREDENTIALS_DIR'}
    env.update(extra)
    return env


class Base(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='setup-dev-env-opt-outs-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runner_temp = self.root / 'runner_temp'
        self.runner_temp.mkdir()
        self.github_env = self.root / 'github_env'
        self.github_output = self.root / 'github_output'
        self.github_env.write_text('')
        self.github_output.write_text('')

    def bash(self, script, **env):
        return subprocess.run(
            ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
            env=clean_environment(RUNNER_TEMP=str(self.runner_temp),
                                  GITHUB_ENV=str(self.github_env),
                                  GITHUB_OUTPUT=str(self.github_output),
                                  GITHUB_ACTION_PATH=str(HERE), **env),
            capture_output=True, text=True, timeout=120)


class ValidateGitAccess(Base):
    def validate(self, access):
        body = step_body(VALIDATE, [('${{ inputs.env-flavor }}', 'reprobuild')])
        return self.bash(body, GIT_ACCESS=access, MCL_CONSUMER_ROOT=str(self.root))

    def test_none_is_accepted(self):
        done = self.validate('none')
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_read_and_write_are_still_accepted(self):
        for access in ('read', 'write'):
            done = self.validate(access)
            self.assertEqual(done.returncode, 0, access + ': ' + done.stderr)

    def test_a_misspelt_value_names_all_three(self):
        done = self.validate('push')
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("git-access must be 'read', 'write' or 'none'", done.stderr)


class RecordGitAccess(Base):
    def record(self, **env):
        return self.bash('bash "' + str(step_script(RECORD)) + '"', GIT_ACCESS='none', **env)

    def test_a_new_credential_directory_holds_the_declaration(self):
        done = self.record()
        self.assertEqual(done.returncode, 0, done.stderr)
        exported = read_env(self.github_env)
        directory = Path(exported['MCL_JOB_CREDENTIALS_DIR'])
        self.assertEqual((directory / 'git-access').read_text(), 'none\n')
        self.assertEqual(set(exported), {'MCL_JOB_CREDENTIALS_DIR'})

    def test_an_existing_credential_directory_is_reused(self):
        existing = self.runner_temp / 'broker-dir'
        existing.mkdir(mode=0o700)
        done = self.record(MCL_JOB_CREDENTIALS_DIR=str(existing))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((existing / 'git-access').read_text(), 'none\n')
        self.assertEqual(read_env(self.github_env), {})

    def test_the_starting_git_configuration_is_an_output(self):
        done = self.record(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.autocrlf',
            GIT_CONFIG_VALUE_0='false')
        self.assertEqual(done.returncode, 0, done.stderr)
        outputs = read_env(self.github_output)
        self.assertEqual(outputs.get('git-config-count'), '1')
        self.assertEqual(outputs.get('git-config-parameters'), 'unset')

    def test_no_installer_configures_git_afterwards(self):
        # End to end: the real configure-git-auth.sh, in the job environment
        # the recording step produced, with a token to install.
        done = self.record()
        self.assertEqual(done.returncode, 0, done.stderr)
        job = read_env(self.github_env)
        self.github_env.write_text('')
        configure = ROOT / 'setup-nix' / 'configure-git-auth.sh'
        home = self.root / 'home'
        home.mkdir()
        done = self.bash('bash "' + str(configure) + '"', HOME=str(home),
            GH_TOKEN='ghs_test_sentinel_token', **job)
        self.assertEqual(done.returncode, 0, done.stderr)
        exported = read_env(self.github_env)
        self.assertFalse([n for n in exported if n.startswith('GIT_CONFIG')], exported)
        self.assertFalse((Path(job['MCL_JOB_CREDENTIALS_DIR']) / 'git-token').exists())


class CheckGitUntouched(Base):
    def check(self, start_count, start_parameters='unset', **env):
        return self.bash('bash "' + str(step_script(CHECK)) + '"',
            START_GIT_CONFIG_COUNT=start_count,
            START_GIT_CONFIG_PARAMETERS=start_parameters, **env)

    def test_an_unchanged_configuration_passes(self):
        self.assertEqual(self.check('unset').returncode, 0)
        done = self.check('1', GIT_CONFIG_COUNT='1')
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_job_scoped_credential_installed_anyway_fails(self):
        done = self.check('unset', GIT_CONFIG_COUNT='3')
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('git-access none', done.stderr)

    def test_new_git_config_parameters_fail(self):
        done = self.check('unset', GIT_CONFIG_PARAMETERS="'http.extraheader'='x'")
        self.assertNotEqual(done.returncode, 0)


STAND_IN_REPRO = '''#!/usr/bin/env bash
# `repro exec -- <command...>`: run the command only when the build
# environment the source build wrote is present.
[ "$1" = exec ] && [ "$2" = -- ] || exit 64
[ "${RUNQUOTAD_BIN:-}" = /kept/runquotad ] || { echo "RUNQUOTAD_BIN not loaded" >&2; exit 65; }
command -v kept-tool >/dev/null || { echo "build path not loaded" >&2; exit 66; }
shift 2
exec "$@"
'''


@unittest.skipIf(WINDOWS, 'stand-ins are POSIX scripts')
class VerifyLoadsTheBuildEnvironment(Base):
    def setUp(self):
        super().setUp()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        repro = self.bin / 'repro'
        repro.write_text(STAND_IN_REPRO)
        repro.chmod(repro.stat().st_mode | stat.S_IXUSR)
        self.kept_path = self.root / 'kept-path'
        self.kept_path.mkdir()
        tool = self.kept_path / 'kept-tool'
        tool.write_text('#!/bin/sh\n')
        tool.chmod(0o755)
        self.build_env = self.root / 'build-env'
        self.build_env.mkdir()
        (self.build_env / 'env').write_text('RUNQUOTAD_BIN=/kept/runquotad\n')
        (self.build_env / 'path').write_text(str(self.kept_path) + '\n')

    def verify(self, **env):
        path = str(self.bin) + os.pathsep + os.environ['PATH']
        return self.bash(step_body(VERIFY), PATH=path, **env)

    def test_the_check_runs_with_the_files_loaded(self):
        done = self.verify(BUILD_ENV_DIR=str(self.build_env))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('setup-dev-env: repro exec witness v1', done.stdout)

    def test_without_the_files_the_stand_in_refuses(self):
        # Control: the stand-in really depends on the loaded environment.
        done = self.verify()
        self.assertNotEqual(done.returncode, 0)


class Wiring(unittest.TestCase):
    def test_the_build_env_input_reaches_setup_reprobuild(self):
        self.assertIn('export-build-env: ${{ inputs.export-build-env }}', step(INSTALL))

    def test_the_verify_step_gets_the_directory(self):
        self.assertIn('BUILD_ENV_DIR: ${{ steps.repro-cli.outputs.build-env-dir }}', step(VERIFY))

    def test_the_reprobuild_git_step_is_skipped_for_none(self):
        condition = [l for l in step(CONFIGURE).splitlines() if l.startswith('      if: ')]
        self.assertEqual(len(condition), 1, condition)
        self.assertIn("inputs.git-access != 'none'", condition[0])

    def test_the_declaration_is_recorded_before_any_installer(self):
        text = action_text()
        record = text.index('    - name: ' + RECORD + '\n')
        for installer in ('uses: metacraft-labs/metacraft-github-actions/setup-nix@',
                          'setup-nix/configure-git-auth.sh'):
            first = text.index(installer)
            self.assertLess(record, first, installer)

    def test_the_check_is_the_last_step_and_reads_the_recording(self):
        text = action_text()
        last = text.rsplit('\n    - name: ', 1)[1]
        self.assertTrue(last.startswith(CHECK), last.splitlines()[0])
        self.assertIn("if: ${{ inputs.git-access == 'none' }}", last)
        self.assertIn('START_GIT_CONFIG_COUNT: ${{ steps.git-access.outputs.git-config-count }}', last)
        self.assertIn('id: git-access', step(RECORD))


if __name__ == '__main__':
    unittest.main()
