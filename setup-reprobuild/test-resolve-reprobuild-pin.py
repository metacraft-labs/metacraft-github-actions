"""Contract tests for resolve-reprobuild-pin.sh and check-installed-repro.sh.

The real scripts run as subprocesses against real pin files: the committed
pins/reprobuild.json and fixtures written next to a copy of the scripts. The
Windows reader (read-pin.ps1, ConvertFrom-Json) runs whenever `pwsh` is on
PATH, which it is on every GitHub-hosted runner; set REQUIRE_PWSH=1 to make
its absence a failure rather than a skip. Only the `repro` CLI in the
check-installed-repro cases is a stand-in that prints a version line.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PIN = json.loads((REPO / 'pins' / 'reprobuild.json').read_text())
OTHER = '0123456789abcdef0123456789abcdef01234567'
PWSH = shutil.which('pwsh')


def parse_output(path):
    if not path.exists():
        return {}
    return dict(line.split('=', 1) for line in path.read_text().splitlines())


class ResolvePin(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='resolve-pin-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        # The script reads ../pins/reprobuild.json beside its own directory.
        (self.root / 'setup-reprobuild').mkdir()
        (self.root / 'pins').mkdir()
        for name in ('resolve-reprobuild-pin.sh', 'read-pin.ps1'):
            shutil.copy(HERE / name, self.root / 'setup-reprobuild' / name)
        self.write_pin(PIN)
        self.runs = 0

    def write_pin(self, pin):
        body = pin if isinstance(pin, str) else json.dumps(pin, indent=2)
        (self.root / 'pins' / 'reprobuild.json').write_text(body)

    def resolve(self, windows=False, **env):
        self.runs += 1
        output = self.root / f'output-{self.runs}'
        full = {k: v for k, v in os.environ.items()
                if k not in ('REPRO_VERSION', 'REPRO_BUILD_PIN', 'FROM_SOURCE',
                              'REPRO_PIN_FILE', 'RUNNER_OS', 'GITHUB_OUTPUT')}
        full.update(env, GITHUB_OUTPUT=str(output))
        if windows:
            full['RUNNER_OS'] = 'Windows'
        result = subprocess.run(
            ['bash', str(self.root / 'setup-reprobuild' / 'resolve-reprobuild-pin.sh')],
            env=full, text=True, capture_output=True, timeout=60)
        return result, parse_output(output)

    def readers(self):
        yield False
        if PWSH:
            yield True
        elif os.environ.get('REQUIRE_PWSH') == '1':
            self.fail('REQUIRE_PWSH=1 but pwsh is not on PATH')

    def test_the_committed_pin_is_installed_by_default(self):
        for windows in self.readers():
            with self.subTest(windows=windows):
                result, out = self.resolve(windows)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(out, {
                    'origin': 'pin', 'pin-commit': PIN['rev'],
                    'pin-version': PIN['version'], 'pin-kind': PIN['kind'],
                    'release-version': '', 'build-ref': PIN['rev'],
                    'from-source': 'true', 'expected-version': PIN['version'],
                    'expected-commit': PIN['rev']})

    def test_the_first_pin_is_v0_2_34_on_agents(self):
        self.assertEqual((PIN['owner'], PIN['repo'], PIN['rev'], PIN['version'], PIN['kind']),
                          ('metacraft-labs', 'reprobuild',
                          'd1bf1f065aca01b90c3bbdddc57d14e977f49e1a', '0.2.34',
                          'agents-commit'))

    def test_a_release_pin_installs_its_release_and_falls_back_to_its_commit(self):
        self.write_pin({**PIN, 'kind': 'release'})
        for windows in self.readers():
            with self.subTest(windows=windows):
                result, out = self.resolve(windows)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['release-version'], 'v' + PIN['version'])
                self.assertEqual(out['build-ref'], PIN['rev'])
                self.assertEqual(out['from-source'], 'false')
                result, out = self.resolve(windows, FROM_SOURCE='true')
                self.assertEqual((out['release-version'], out['from-source']), ('', 'true'))

    def test_overrides_replace_the_pin(self):
        cases = [
            (dict(REPRO_BUILD_PIN=OTHER), '', OTHER, 'true', OTHER),
            (dict(REPRO_VERSION='v0.2.31'), 'v0.2.31', '', 'false', ''),
            (dict(REPRO_VERSION='0.2.31', REPRO_BUILD_PIN=OTHER), '0.2.31', OTHER, 'false', OTHER),
            (dict(REPRO_VERSION='0.2.31', FROM_SOURCE='true'), '', 'v0.2.31', 'true', ''),
        ]
        for env, release, ref, source, commit in cases:
            with self.subTest(env=env):
                result, out = self.resolve(**env)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['origin'], 'override')
                self.assertEqual(out['release-version'], release)
                self.assertEqual(out['build-ref'], ref)
                self.assertEqual(out['from-source'], source)
                self.assertEqual(out['expected-commit'], commit)
                self.assertEqual(out['expected-version'], '')

    def test_a_source_build_of_latest_names_no_revision(self):
        result, out = self.resolve(REPRO_VERSION='latest', FROM_SOURCE='true')
        self.assertEqual(result.returncode, 1)
        self.assertIn('names no revision', result.stdout)
        self.assertEqual(out, {})

    def test_no_selection_is_a_branch(self):
        for env in ({}, dict(FROM_SOURCE='true')):
            result, out = self.resolve(**env)
            self.assertNotIn(out['build-ref'], ('dev', 'agents', 'main', 'latest'))

    def test_an_invalid_pin_fails_with_no_selection(self):
        bad = [
            ({**PIN, 'rev': PIN['rev'][:39]}, 'rev'),
            ({**PIN, 'rev': 'agents'}, 'rev'),
            ({**PIN, 'rev': PIN['rev'].upper()}, 'rev'),
            ({**PIN, 'repo': 'other'}, 'not metacraft-labs/reprobuild'),
            ({**PIN, 'schema': 2}, 'schema'),
            ({**PIN, 'kind': 'branch'}, 'kind'),
            ({k: v for k, v in PIN.items() if k != 'kind'}, 'kind'),
            ({k: v for k, v in PIN.items() if k != 'version'}, 'version'),
            ({**PIN, 'version': 'dev'}, 'version'),
        ]
        for pin, message in bad:
            for windows in self.readers():
                with self.subTest(pin=pin, windows=windows):
                    self.write_pin(pin)
                    result, out = self.resolve(windows)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn('::error::', result.stdout)
                    self.assertIn(message, result.stdout)
                    self.assertEqual(out, {})

    def test_a_missing_pin_fails(self):
        (self.root / 'pins' / 'reprobuild.json').unlink()
        result, out = self.resolve()
        self.assertEqual(result.returncode, 1)
        self.assertIn('does not exist', result.stdout)
        self.assertEqual(out, {})

    def test_the_windows_reader_refuses_what_is_not_json(self):
        if not PWSH:
            if os.environ.get('REQUIRE_PWSH') == '1':
                self.fail('REQUIRE_PWSH=1 but pwsh is not on PATH')
            self.skipTest('pwsh is not on PATH')
        self.write_pin('{"rev": ')
        result, out = self.resolve(windows=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('could not read the Reprobuild pin', result.stdout)
        self.assertEqual(out, {})


class CheckInstalled(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='check-repro-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.runs = 0

    def cli(self, line):
        cli = self.bin / 'repro'
        cli.write_text(f'#!/bin/sh\nprintf "%s\\n" "{line}"\n')
        cli.chmod(0o755)

    def check(self, **env):
        self.runs += 1
        output = self.root / f'output-{self.runs}'
        full = dict(os.environ, GITHUB_OUTPUT=str(output), REPRO_BIN_DIR=str(self.bin))
        full.pop('RUNNER_OS', None)
        full.update(env)
        result = subprocess.run(['bash', str(HERE / 'check-installed-repro.sh')],
                                env=full, text=True, capture_output=True, timeout=30)
        return result, parse_output(output)

    def source_checkout(self):
        source = self.root / 'source'
        quiet = dict(capture_output=True, text=True, check=True)
        subprocess.run(['git', 'init', '-q', str(source)], **quiet)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=t', '-c', 'user.email=t@t',
                        'commit', '-q', '--allow-empty', '-m', 'pin'], **quiet)
        head = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], **quiet).stdout.strip()
        return source, head

    def test_the_pinned_version_passes_and_is_reported(self):
        self.cli('repro 0.2.34')
        result, out = self.check(EXPECTED_VERSION='0.2.34')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out, {'version': '0.2.34', 'commit': ''})

    def test_a_crlf_version_line_matches(self):
        self.cli('repro 0.2.34\r')
        result, out = self.check(EXPECTED_VERSION='0.2.34')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['version'], '0.2.34')

    def test_another_version_fails(self):
        self.cli('repro 0.2.31')
        result, out = self.check(EXPECTED_VERSION='0.2.34')
        self.assertEqual(result.returncode, 1)
        self.assertIn("reports 'repro 0.2.31'", result.stdout)
        self.assertEqual(out, {})

    def test_an_override_reports_without_comparing(self):
        self.cli('repro 0.2.31')
        result, out = self.check(EXPECTED_VERSION='')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['version'], '0.2.31')

    def test_a_source_build_reports_and_checks_its_commit(self):
        self.cli('repro 0.2.34')
        source, head = self.source_checkout()
        result, out = self.check(EXPECTED_VERSION='0.2.34', EXPECTED_COMMIT=head,
                                  SOURCE_DIR=str(source))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out, {'version': '0.2.34', 'commit': head})
        result, out = self.check(EXPECTED_VERSION='0.2.34', EXPECTED_COMMIT=OTHER,
                                  SOURCE_DIR=str(source))
        self.assertEqual(result.returncode, 1)
        self.assertIn('not the selected ' + OTHER, result.stdout)
        self.assertEqual(out, {})

    def test_output_that_is_not_a_version_fails(self):
        self.cli('usage: repro <command>')
        result, out = self.check(EXPECTED_VERSION='')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(out, {})


if __name__ == '__main__':
    unittest.main()
