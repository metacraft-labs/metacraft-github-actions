"""setup-dev-env names the Reprobuild commit it installed, on every route.

Consumer workflows used to assert `git -C .reprobuild-src rev-parse HEAD`
against a literal revision. They now compare against setup-dev-env's
`repro-commit` output, so the revision lives only in pins/reprobuild.json
(metacraft-pm milestones/Single-Tool-Pins.milestones.org, STP2, decision D1).
That only works if the output is never empty when a `repro` was installed,
whatever route installed it.

Two halves:

- The wiring. action.yml's `repro-commit`, `repro-version`, `repro-origin` and
  `repro-install-source` outputs read the step "Report the installed
  Reprobuild (reprobuild)", that step runs exactly when the CLI install does,
  after the check step, and its environment names the selection, install and
  check steps' outputs it needs. Read from the real action.yml as text: the
  runner is the only YAML evaluator that matters, and the repository's tests
  parse action.yml the same way.
- The behaviour. The step's real script, report-installed-repro.sh, runs
  under bash with a temporary GITHUB_OUTPUT for each install route
  setup-reprobuild has (`source` on Linux/macOS Nix and the Windows env.ps1
  build look the same to this step: a checkout commit; `package`, `cache`,
  `pin-release`; `release` for a pin and for an override), and for the inputs
  that must fail closed. A release override is resolved against a real local
  Git repository with annotated and lightweight tags, through REPRO_SOURCE_URL.
  That local repository stands in for github.com/metacraft-labs/reprobuild:
  the property is how `git ls-remote` output becomes a commit, and a network
  dependency would make the suite fail for reasons unrelated to it. Nothing
  else is stubbed.

Run: python3 setup-dev-env/test-repro-commit-output.py
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ACTION = HERE / 'action.yml'
SCRIPT = HERE / 'report-installed-repro.sh'

INSTALL = 'Install the repro CLI (reprobuild)'
CHECK = 'Check the installed repro is the selected one (reprobuild)'
REPORT = 'Report the installed Reprobuild (reprobuild)'
SELECT = 'Select the Reprobuild revision (reprobuild)'

PIN = 'abcdef0123456789abcdef0123456789abcdef01'  # synthetic; no real revision
OTHER = '1111111111111111111111111111111111111111'


def action_text():
    return ACTION.read_text(encoding='utf-8')


def step(name):
    marker = '    - name: ' + name + '\n'
    text = action_text()
    if marker not in text:
        raise AssertionError('action.yml has no step named ' + repr(name))
    return text.split(marker, 1)[1].split('\n    - name: ', 1)[0]


def step_field(name, field):
    match = re.search(r'^      ' + re.escape(field) + r': (.*)$', step(name), re.M)
    if not match:
        raise AssertionError(name + ' has no ' + field)
    return match.group(1).strip()


def step_env(name):
    body = step(name).split('      env:\n', 1)[1]
    env = {}
    for line in body.splitlines():
        if not line.startswith('        '):
            break
        key, _, value = line.strip().partition(': ')
        env[key] = value
    return env


def action_outputs():
    block = action_text().split('\noutputs:\n', 1)[1].split('\nruns:\n', 1)[0]
    return dict(re.findall(r'^  ([a-z-]+):\n(?:    .*\n)*?    value: (.*)$', block, re.M))


class Wiring(unittest.TestCase):
    def test_outputs_read_the_report_step(self):
        outputs = action_outputs()
        for output, key in (('repro-commit', 'commit'), ('repro-version', 'version'),
                            ('repro-origin', 'origin'),
                            ('repro-install-source', 'install-source')):
            self.assertEqual(outputs.get(output),
                            '${{ steps.repro-report.outputs.' + key + ' }}', output)

    def test_report_step_runs_whenever_the_cli_is_installed(self):
        self.assertEqual(step_field(REPORT, 'id'), 'repro-report')
        self.assertEqual(step_field(REPORT, 'if'), step_field(INSTALL, 'if'))
        self.assertEqual(step_field(CHECK, 'if'), step_field(INSTALL, 'if'))
        self.assertEqual(step_field(REPORT, 'run'),
                        'bash "${GITHUB_ACTION_PATH}/report-installed-repro.sh"')

    def test_report_step_follows_the_check(self):
        text = action_text()
        order = [text.index('    - name: ' + name + '\n')
                for name in (SELECT, INSTALL, CHECK, REPORT)]
        self.assertEqual(order, sorted(order))

    def test_report_step_reads_the_right_outputs(self):
        self.assertEqual(step_field(SELECT, 'id'), 'repro-pin')
        self.assertEqual(step_field(INSTALL, 'id'), 'repro-cli')
        self.assertEqual(step_field(CHECK, 'id'), 'repro-check')
        self.assertEqual(step_env(REPORT), {
            'INSTALL_SOURCE': '${{ steps.repro-cli.outputs.install-source }}',
            'ORIGIN': '${{ steps.repro-pin.outputs.origin }}',
            'PIN_COMMIT': '${{ steps.repro-pin.outputs.pin-commit }}',
            'PIN_KIND': '${{ steps.repro-pin.outputs.pin-kind }}',
            'BUILD_REF': '${{ steps.repro-pin.outputs.build-ref }}',
            'RELEASE_VERSION': '${{ steps.repro-pin.outputs.release-version }}',
            'CHECKED_VERSION': '${{ steps.repro-check.outputs.version }}',
            'CHECKED_COMMIT': '${{ steps.repro-check.outputs.commit }}',
        })

    def test_the_selection_and_check_scripts_produce_what_the_report_reads(self):
        resolver = (ROOT / 'setup-reprobuild' / 'resolve-reprobuild-pin.sh').read_text(encoding='utf-8')
        for key in ('origin', 'pin-commit', 'pin-kind', 'build-ref', 'release-version'):
            self.assertIn("printf '" + key + "=%s\\n'", resolver, key)
        checker = (ROOT / 'setup-reprobuild' / 'check-installed-repro.sh').read_text(encoding='utf-8')
        self.assertIn("printf 'version=%s\\ncommit=%s\\n'", checker)
        installer = (ROOT / 'setup-reprobuild' / 'action.yml').read_text(encoding='utf-8')
        self.assertIn('\noutputs:\n  install-source:\n', installer)


class Report(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='repro-commit-output-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'github_output'

    def run_report(self, **env):
        self.output.write_text('')
        base = {name: value for name, value in os.environ.items()
                if name not in ('INSTALL_SOURCE', 'ORIGIN', 'PIN_COMMIT', 'PIN_KIND',
                                'BUILD_REF', 'RELEASE_VERSION', 'CHECKED_VERSION',
                                'CHECKED_COMMIT', 'REPRO_SOURCE_URL')}
        base.update({'GITHUB_OUTPUT': str(self.output), 'ORIGIN': 'pin',
                    'PIN_COMMIT': PIN, 'PIN_KIND': 'agents-commit', 'BUILD_REF': PIN,
                    'CHECKED_VERSION': '9.8.7',
                    'REPRO_SOURCE_URL': str(self.root / 'nowhere.git')})
        base.update(env)
        # Resolve bash from PATH first: on Windows a bare name goes to
        # CreateProcess, which searches System32 before PATH and finds WSL's
        # launcher instead of the Git Bash that runs the step.
        bash = shutil.which('bash')
        self.assertIsNotNone(bash, 'the suite needs bash')
        result = subprocess.run([bash, str(SCRIPT)], env=base, text=True,
                                capture_output=True)
        outputs = dict(line.split('=', 1)
                      for line in self.output.read_text().splitlines() if line)
        return result, outputs

    def assertReports(self, commit, origin='pin', **env):
        result, outputs = self.run_report(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(outputs, {'commit': commit, 'version': env.get('CHECKED_VERSION', '9.8.7'),
                                  'origin': origin,
                                  'install-source': env['INSTALL_SOURCE']})

    def assertFailsClosed(self, message, **env):
        result, outputs = self.run_report(**env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        self.assertEqual(outputs, {}, 'a failing report must write no output')

    # Source builds: Linux/macOS Nix and Windows env.ps1 alike.
    def test_source_build_reports_its_checkout(self):
        self.assertReports(PIN, INSTALL_SOURCE='source', CHECKED_COMMIT=PIN)

    def test_source_build_of_a_branch_override_reports_the_resolved_commit(self):
        self.assertReports(OTHER, origin='override', INSTALL_SOURCE='source',
                          ORIGIN='override', BUILD_REF='some-branch',
                          CHECKED_COMMIT=OTHER, CHECKED_VERSION='0.3.0-dev')

    def test_source_build_without_a_checkout_commit_fails(self):
        self.assertFailsClosed('read no commit', INSTALL_SOURCE='source', CHECKED_COMMIT='')

    # Package, binary cache and Windows pin prerelease: the full-SHA build ref.
    def test_artifact_routes_report_the_build_ref(self):
        for route in ('package', 'cache', 'pin-release'):
            with self.subTest(route=route):
                self.assertReports(PIN, INSTALL_SOURCE=route)
                self.assertReports(OTHER, origin='override', INSTALL_SOURCE=route,
                                  ORIGIN='override', BUILD_REF=OTHER)

    def test_artifact_routes_refuse_a_ref_that_is_not_a_full_sha(self):
        for ref in ('', 'v9.8.7', PIN[:12], PIN.upper()):
            with self.subTest(ref=ref):
                self.assertFailsClosed('full commit SHA', INSTALL_SOURCE='cache', BUILD_REF=ref)

    # Release archives.
    def test_release_pin_reports_the_pinned_rev(self):
        self.assertReports(PIN, INSTALL_SOURCE='release', PIN_KIND='release',
                          BUILD_REF=PIN, RELEASE_VERSION='v9.8.7')

    def test_release_install_for_a_commit_pin_fails(self):
        self.assertFailsClosed('names no release', INSTALL_SOURCE='release',
                              PIN_KIND='agents-commit')

    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd, check=True, text=True,
                              capture_output=True,
                              env={**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull,
                                  'GIT_CONFIG_NOSYSTEM': '1',
                                  'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.com',
                                  'GIT_COMMITTER_NAME': 't',
                                  'GIT_COMMITTER_EMAIL': 't@example.com'}).stdout.strip()

    def release_repository(self):
        """A repository with an annotated v9.8.1 and a lightweight v9.8.2."""
        repo = self.root / 'reprobuild'
        repo.mkdir()
        self.git('init', '-q', cwd=repo)
        self.git('commit', '-q', '--allow-empty', '-m', 'one', cwd=repo)
        first = self.git('rev-parse', 'HEAD', cwd=repo)
        self.git('tag', '-a', '-m', 'release', 'v9.8.1', cwd=repo)
        self.git('commit', '-q', '--allow-empty', '-m', 'two', cwd=repo)
        second = self.git('rev-parse', 'HEAD', cwd=repo)
        self.git('tag', 'v9.8.2', cwd=repo)
        tag_object = self.git('rev-parse', 'v9.8.1', cwd=repo)
        self.assertNotEqual(tag_object, first, 'v9.8.1 must be an annotated tag')
        return repo, first, second

    def test_release_override_resolves_its_tag(self):
        repo, first, second = self.release_repository()
        override = dict(INSTALL_SOURCE='release', ORIGIN='override', BUILD_REF='',
                        REPRO_SOURCE_URL=str(repo))
        # Annotated: the peeled commit, not the tag object.
        self.assertReports(first, origin='override', RELEASE_VERSION='v9.8.1',
                          CHECKED_VERSION='9.8.1', **override)
        # A bare version names the same tag.
        self.assertReports(first, origin='override', RELEASE_VERSION='9.8.1',
                          CHECKED_VERSION='9.8.1', **override)
        # Lightweight.
        self.assertReports(second, origin='override', RELEASE_VERSION='v9.8.2',
                          CHECKED_VERSION='9.8.2', **override)
        # `latest` names no tag; the installed version does.
        self.assertReports(second, origin='override', RELEASE_VERSION='latest',
                          CHECKED_VERSION='9.8.2', **override)

    def test_release_override_with_an_unknown_tag_fails(self):
        repo, _, _ = self.release_repository()
        self.assertFailsClosed('does not exist', INSTALL_SOURCE='release', ORIGIN='override',
                              BUILD_REF='', RELEASE_VERSION='v9.9.9',
                              CHECKED_VERSION='9.9.9', REPRO_SOURCE_URL=str(repo))

    def test_release_override_with_an_unreachable_repository_fails(self):
        self.assertFailsClosed('cannot resolve', INSTALL_SOURCE='release', ORIGIN='override',
                              BUILD_REF='', RELEASE_VERSION='v9.8.1',
                              CHECKED_VERSION='9.8.1')

    # Inputs that are not a known install.
    def test_unknown_route_fails(self):
        for route in ('', 'nix-profile'):
            with self.subTest(route=route):
                self.assertFailsClosed('does not know', INSTALL_SOURCE=route)

    def test_unknown_origin_fails(self):
        self.assertFailsClosed('not pin or override', INSTALL_SOURCE='source',
                              CHECKED_COMMIT=PIN, ORIGIN='')

    def test_missing_version_fails(self):
        self.assertFailsClosed('no version', INSTALL_SOURCE='source', CHECKED_COMMIT=PIN,
                              CHECKED_VERSION='')

    def test_a_checkout_commit_that_is_not_a_sha_fails(self):
        self.assertFailsClosed('not a full lowercase commit SHA', INSTALL_SOURCE='source',
                              CHECKED_COMMIT='dev')


if __name__ == '__main__':
    unittest.main()
