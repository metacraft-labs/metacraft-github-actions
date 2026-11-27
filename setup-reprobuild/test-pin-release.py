"""Install the selected commit's Windows bundle from its pin prerelease.

The `pins` workflow publishes the pinned Reprobuild commit's release-style
bundle as the prerelease `pin-<commit>` of this repository, and
setup-reprobuild installs it on Windows instead of compiling the commit
(install-pin-release.sh, through install-release.sh). A hit must install and
be verified; a miss (no prerelease, no archive for the platform) must take the
source route quietly; a prerelease that fails verification must fail the step
and never fall back.

Mocks, and why. The release origin is a local HTTP server serving what
github.com's release download URLs serve (200 with the asset, 404 for a
missing release or asset), because the installer's routing is decided by
those statuses and a real prerelease cannot be created and destroyed per test.
The archive is real (tar.gz, real SHA-256, real unpacking and containment);
only the `repro` inside it is a two-line script, because qualifying the SDK
itself belongs to reprobuild's release checks, which the producing job runs.
The archive is the host platform's (tar.gz on Linux and macOS): the same
install-release.sh code selects the Windows zip by `uname`, which a Linux test
host cannot impersonate. Everything else is the real script, run by Bash.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
ACTION = HERE / 'action.yml'
SHA = '0123456789abcdef0123456789abcdef01234567'
PIN_REPO = 'metacraft-labs/metacraft-github-actions'
STEP = "Install the selected commit's pin prerelease (Windows)"


def step_lines(name, action=ACTION):
    lines = action.read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_body(name, action=ACTION):
    lines = step_lines(name, action)
    run = lines.index('      run: |')
    return '\n'.join(line[8:] if line.startswith('        ') else ''
                      for line in lines[run + 1:]) + '\n'


def condition(name):
    return next(line for line in step_lines(name) if line.startswith('      if: '))


def evaluate(test, context):
    """Evaluate a step's `if:` against `context`, a map from expression
    references (`runner.os`, `inputs.from-source`, ...) to their values.

    Only the shape these conditions use is accepted: `${{ a && b && ... }}`
    of `<reference> == '<literal>'` or `!=` clauses. Anything else is a
    failure, not a guess, so a condition rewritten into another shape makes
    the caller's assertion fail instead of passing vacuously. GitHub compares
    strings case-insensitively
    (https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#operators),
    and so does this. A reference missing from `context` is a KeyError."""
    match = re.fullmatch(r'      if: \$\{\{ (.*) \}\}', test)
    if match is None:
        raise ValueError(f'not a plain expression condition: {test!r}')
    result = True
    for clause in match.group(1).split(' && '):
        parsed = re.fullmatch(r"([a-z][a-z0-9_.-]*) (==|!=) '([^']*)'", clause.strip())
        if parsed is None:
            raise ValueError(f'unsupported clause: {clause!r}')
        reference, operator, literal = parsed.groups()
        equal = context[reference].lower() == literal.lower()
        result = result and (equal if operator == '==' else not equal)
    return result


class PinPrerelease(unittest.TestCase):
    """The real install-pin-release.sh against a local release origin."""

    scripts = HERE

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='repro-pin-release-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        machine = platform.machine().lower()
        self.arch = {'x86_64': 'x86_64', 'amd64': 'x86_64',
                      'arm64': 'aarch64', 'aarch64': 'aarch64'}[machine]
        self.os_name = {'Linux': 'linux', 'Darwin': 'darwin'}[platform.system()]
        self.routes = {}
        self.requests = []
        routes, requests = self.routes, self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(handler):
                requests.append(handler.path)
                status, body = routes.get(handler.path, (404, b'Not Found'))
                handler.send_response(status)
                handler.send_header('Content-Length', str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('REPRO_', 'GITHUB_', 'GH_TOKEN', 'EXPECTED_'))}
        origin = f'http://127.0.0.1:{server.server_port}'
        self.env.update(REPRO_RELEASE_DOWNLOAD_ORIGIN=origin,
                        REPRO_RELEASE_API_ORIGIN=origin,
                        REPRO_BUILD_PIN=SHA, EXPECTED_VERSION='1.2.3',
                        RUNNER_TEMP=str(self.root),
                        GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_PATH=str(self.root / 'path'))
        self.prefix = f'/{PIN_REPO}/releases/download/pin-{SHA}/'

    def asset(self, version='1.2.3'):
        return f'reprobuild-{version}-{self.os_name}-{self.arch}.tar.gz'

    def publish(self, version='1.2.3', reported=None, digest=None, sums=True,
                archive=True, extra_sums=''):
        """Serve the prerelease: an archive whose CLI reports `reported`, and
        a SHA256SUMS line for it with `digest` (default: the real one)."""
        name = f'reprobuild-{version}-{self.os_name}-{self.arch}'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as tar:
            body = f'#!/bin/sh\nprintf "%s\\n" "repro {reported or version}"\n'.encode()
            entry = tarfile.TarInfo(name + '/bin/repro')
            entry.size, entry.mode = len(body), 0o755
            tar.addfile(entry, io.BytesIO(body))
        payload = data.getvalue()
        if sums:
            line = f'{digest or hashlib.sha256(payload).hexdigest()}  {name}.tar.gz\n'
            self.routes[self.prefix + 'SHA256SUMS'] = (200, (line + extra_sums).encode())
        if archive:
            self.routes[self.prefix + name + '.tar.gz'] = (200, payload)

    def run_script(self, **overrides):
        self.env.update(overrides)
        return subprocess.run(['bash', str(self.scripts / 'install-pin-release.sh')],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def written(self, name):
        path = self.root / name
        return path.read_text().splitlines() if path.exists() else []

    def assert_installed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        bin_dir = str(self.root / 'reprobuild-pin-release' / 'bin')
        self.assertEqual(self.written('output'), [f'bin-dir={bin_dir}'])
        self.assertEqual(self.written('path'), [bin_dir])
        self.assertTrue((Path(bin_dir) / 'repro').is_file())

    def assert_source_route(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.written('output'), [])
        self.assertEqual(self.written('path'), [])
        self.assertIn('::notice::', result.stdout)

    def assert_hard_failure(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('::error::', result.stdout)
        self.assertIn('Not falling back', result.stdout)
        self.assertEqual(self.written('output'), [])
        self.assertEqual(self.written('path'), [])

    # ── hits ────────────────────────────────────────────────────────────────

    def test_a_published_prerelease_is_installed_from_this_repository(self):
        self.publish()
        result = self.run_script()
        self.assert_installed(result)
        self.assertEqual(self.requests, [self.prefix + 'SHA256SUMS', self.prefix + self.asset()])
        self.assertIn('sha256 verified', result.stderr)

    def test_without_a_known_version_the_manifest_names_it(self):
        # setup-dev-env forwards the pin as repro-build-pin, so the action has
        # no expected-version; the prerelease's SHA256SUMS supplies it.
        self.publish(version='0.2.34', extra_sums=f'{"a" * 64}  reprobuild-0.2.34-windows-zz.zip\n')
        result = self.run_script(EXPECTED_VERSION='')
        self.assert_installed(result)
        self.assertIn(self.prefix + self.asset('0.2.34'), self.requests)

    # ── misses: the source route ────────────────────────────────────────────

    def test_no_prerelease_takes_the_source_route(self):
        for version in ['1.2.3', '']:
            with self.subTest(expected_version=version):
                self.requests.clear()
                result = self.run_script(EXPECTED_VERSION=version)
                self.assert_source_route(result)
                self.assertEqual(self.requests, [self.prefix + 'SHA256SUMS'])

    def test_a_prerelease_without_this_platforms_archive_takes_the_source_route(self):
        # Only another platform's archive is listed and served.
        other = f'reprobuild-1.2.3-windows-x86_64.zip'
        self.routes[self.prefix + 'SHA256SUMS'] = (200, f'{"b" * 64}  {other}\n'.encode())
        self.routes[self.prefix + other] = (200, b'zip')
        for version in ['1.2.3', '']:
            with self.subTest(expected_version=version):
                result = self.run_script(EXPECTED_VERSION=version)
                self.assert_source_route(result)
                self.assertNotIn(self.prefix + other, self.requests)

    def test_require_checksum_false_does_not_reach_this_route(self):
        # The archive is there but no SHA256SUMS: a release would install it
        # unverified under require-checksum: false; a pin prerelease never does.
        self.publish(sums=False)
        result = self.run_script(REPRO_REQUIRE_CHECKSUM='false')
        self.assert_source_route(result)
        self.assertNotIn(self.prefix + self.asset(), self.requests)

    def test_a_movable_or_abbreviated_selection_asks_for_nothing(self):
        for pin in ['dev', 'v0.2.34', SHA[:12], SHA.upper(), '']:
            with self.subTest(pin=pin):
                result = self.run_script(REPRO_BUILD_PIN=pin)
                self.assert_source_route(result)
        self.assertEqual(self.requests, [])

    # ── wrong prereleases: hard errors ──────────────────────────────────────

    def test_a_checksum_mismatch_fails_and_does_not_fall_back(self):
        for version in ['1.2.3', '']:
            with self.subTest(expected_version=version):
                self.publish(digest='0' * 64)
                result = self.run_script(EXPECTED_VERSION=version)
                self.assert_hard_failure(result)
                self.assertIn('checksum MISMATCH', result.stderr)
                self.assertFalse((self.root / 'reprobuild-pin-release').exists())

    def test_a_cli_reporting_another_version_fails(self):
        self.publish(reported='9.9.9')
        self.assert_hard_failure(self.run_script())
        # The manifest's own version is held to the CLI too.
        self.assert_hard_failure(self.run_script(EXPECTED_VERSION=''))

    def test_a_listed_archive_that_is_not_served_is_not_a_hard_failure(self):
        # Half-uploaded prerelease: SHA256SUMS present, the archive 404. The
        # publish job completes it; until then jobs build from source.
        self.publish(archive=False)
        self.assert_source_route(self.run_script())

    def test_an_ambiguous_manifest_fails(self):
        self.publish(extra_sums=f'{"c" * 64}  {self.asset("1.2.4")}\n')
        result = self.run_script(EXPECTED_VERSION='')
        self.assert_hard_failure(result)
        self.assertIn('more than one', result.stderr)

    def test_an_implausible_version_in_the_manifest_fails(self):
        bad = f'reprobuild-1.2.3;x-{self.os_name}-{self.arch}.tar.gz'
        self.routes[self.prefix + 'SHA256SUMS'] = (200, f'{"d" * 64}  {bad}\n'.encode())
        result = self.run_script(EXPECTED_VERSION='')
        self.assert_hard_failure(result)
        self.assertIn('implausible version', result.stderr)
        self.assertEqual(self.requests, [self.prefix + 'SHA256SUMS'])

    def test_a_server_error_is_not_a_miss(self):
        self.routes[self.prefix + 'SHA256SUMS'] = (500, b'oops')
        self.assert_hard_failure(self.run_script())


class ReleaseTagInput(unittest.TestCase):
    """REPRO_RELEASE_TAG reaches a URL and a file name like a version does."""

    def test_a_tag_that_is_a_path_is_refused_before_any_request(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('REPRO_', 'GITHUB_'))}
        with tempfile.TemporaryDirectory() as scratch:
            for tag in ['pin-x/../../evil', '../x', 'a b', '-x', '.x', 'pin..x']:
                with self.subTest(tag=tag):
                    env.update(REPRO_RELEASE_TAG=tag, REPRO_VERSION='',
                                REPRO_INSTALL_DIR=str(Path(scratch) / 'i'),
                                REPRO_RELEASE_DOWNLOAD_ORIGIN='http://127.0.0.1:9',
                                REPRO_RELEASE_API_ORIGIN='http://127.0.0.1:9')
                    result = subprocess.run(['bash', str(HERE / 'install-release.sh')],
                                            env=env, text=True, capture_output=True,
                                            timeout=20)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('invalid release tag', result.stderr)

    def test_a_version_release_still_needs_a_version(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('REPRO_', 'GITHUB_'))}
        env.update(REPRO_INSTALL_DIR='/nonexistent/i')
        result = subprocess.run(['bash', str(HERE / 'install-release.sh')], env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn('names no release', result.stderr)


class Wiring(unittest.TestCase):
    """The step's place and condition in the composite, and the decision."""

    def decide(self, action=ACTION, **values):
        with tempfile.TemporaryDirectory(prefix='repro-pin-decide-') as scratch:
            output = Path(scratch) / 'output'
            env = {k: v for k, v in os.environ.items() if not k.startswith(('REPRO_', 'GITHUB_'))}
            env.update(dict(RELEASE_INSTALLED='', RELEASE_BIN_DIR='', RESOLVED_TAG='',
                            REPRO_VERSION='', BUILD_REF=SHA, ORIGIN='pin',
                            REPRO_PACKAGE='', PACKAGE_BIN_DIR='', CACHE_BIN_DIR='',
                            PIN_RELEASE_BIN_DIR='', GITHUB_OUTPUT=str(output)), **values)
            result = subprocess.run(['bash', '-c', step_body('Decide install path', action)],
                                    env=env, text=True, capture_output=True, timeout=10)
            return result, output.read_text().splitlines() if output.exists() else []

    def test_an_installed_prerelease_replaces_the_source_build(self):
        result, output = self.decide(PIN_RELEASE_BIN_DIR='C:/t/reprobuild-pin-release/bin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=pin-release', output)
        self.assertIn('repro-bin-dir=C:/t/reprobuild-pin-release/bin', output)
        self.assertIn('need-source=false', output)

    def test_a_miss_leaves_the_source_route_unchanged(self):
        result, output = self.decide()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', output)
        self.assertIn('need-source=true', output)

    def test_the_step_runs_only_for_a_windows_source_selection_of_a_commit(self):
        test = condition(STEP)
        self.assertIn("runner.os == 'Windows'", test)
        self.assertIn("inputs.repro-package == ''", test)
        self.assertIn("steps.pin.outputs.release-version == ''", test)
        self.assertIn("steps.pin.outputs.expected-commit != ''", test)
        # These build a different engine than the pinned commit's bundle.
        for name in ['runquota-ref', 'io-mon-ref', 'stackable-hooks-pin']:
            self.assertIn(f"inputs.{name} == ''", test)
        # Linux and macOS are untouched by it.
        self.assertNotIn("'Linux'", test)
        self.assertNotIn("'macOS'", test)

    # The context in which the step runs today: a Windows job installing a
    # pinned commit with no build-input override and no source request.
    TAKEN = {
        'runner.os': 'Windows',
        'inputs.repro-package': '',
        'steps.pin.outputs.release-version': '',
        'steps.pin.outputs.expected-commit': SHA,
        'steps.pin.outputs.source-requested': 'false',
        'inputs.runquota-ref': '',
        'inputs.io-mon-ref': '',
        'inputs.stackable-hooks-pin': '',
    }

    def test_a_commit_pin_without_a_source_request_takes_the_prerelease(self):
        self.assertTrue(evaluate(condition(STEP), self.TAKEN))

    def test_a_source_request_skips_the_prerelease_for_the_source_build(self):
        # from-source: true means a source build, at the same pinned commit:
        # a consumer that drives the engine from its source checkout (with
        # runquota next to it) cannot use a bundle. The decision then finds
        # no PIN_RELEASE_BIN_DIR and builds `build-ref`.
        self.assertFalse(evaluate(condition(STEP),
                                  {**self.TAKEN, 'steps.pin.outputs.source-requested': 'true'}))
        result, output = self.decide()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', output)

    def test_the_source_request_is_the_callers_not_the_selection_kind(self):
        # steps.pin.outputs.from-source is `true` for every commit selection,
        # the very case this route serves; gating on it would retire the
        # route for every caller. The input itself would let a non-literal
        # `True` skip the route while the resolver treats it as false.
        test = condition(STEP)
        self.assertNotIn('steps.pin.outputs.from-source', test)
        self.assertNotIn('inputs.from-source', test)

    def test_the_step_asks_for_the_selected_commit(self):
        step = '\n'.join(step_lines(STEP))
        self.assertIn('      id: pin-release', step)
        self.assertIn('REPRO_BUILD_PIN: ${{ steps.pin.outputs.expected-commit }}', step)
        self.assertIn('EXPECTED_VERSION: ${{ steps.pin.outputs.expected-version }}', step)
        self.assertIn('install-pin-release.sh', step)
        self.assertNotIn('require-checksum', step)

    def test_the_step_sits_between_the_installers_and_the_decision(self):
        source = ACTION.read_text()
        order = [source.index('    - name: ' + name) for name in [
            'Install prebuilt repro CLI from GitHub Release',
            'Substitute the selected repro package from the binary cache',
            STEP, 'Decide install path', 'Clone reprobuild source',
            'Build repro CLI (Windows)']]
        self.assertEqual(order, sorted(order))
        decide = '\n'.join(step_lines('Decide install path'))
        self.assertIn('PIN_RELEASE_BIN_DIR: ${{ steps.pin-release.outputs.bin-dir }}', decide)

    def test_the_commit_output_names_the_installed_commit(self):
        self.assertIn("steps.decide.outputs.install-source == 'pin-release'", ACTION.read_text())

    def test_the_windows_source_build_still_leaves_the_nim_compiler_unset(self):
        # fa93d60: the stock Nim env.ps1 provides rejects --compilerArgsFile.
        build = step_body('Build repro CLI (Windows)')
        self.assertIn('"REPRO_NIM_COMPILER"', build)
        self.assertNotIn('REPRO_NIM_COMPILER=', build)


class MutationControls(unittest.TestCase):
    """Each guard above is load-bearing: break it in a copy of the scripts and
    the case that relies on it must change outcome."""

    def mutated(self, name, old, new):
        scratch = Path(tempfile.mkdtemp(prefix='repro-pin-mutant-'))
        self.addCleanup(shutil.rmtree, scratch)
        for script in ['install-pin-release.sh', 'install-release.sh']:
            shutil.copy(HERE / script, scratch / script)
        text = (scratch / name).read_text()
        self.assertEqual(text.count(old), 1, (name, old))
        (scratch / name).write_text(text.replace(old, new))
        return scratch

    def case(self, scripts, test):
        case = PinPrerelease(test)
        case.scripts = scripts
        result = unittest.TestResult()
        case.run(result)
        return result.wasSuccessful()

    def test_the_real_scripts_pass_the_cases_the_mutants_target(self):
        for test in ['test_a_checksum_mismatch_fails_and_does_not_fall_back',
                      'test_require_checksum_false_does_not_reach_this_route',
                      'test_a_prerelease_without_this_platforms_archive_takes_the_source_route',
                      'test_a_published_prerelease_is_installed_from_this_repository']:
            with self.subTest(test=test):
                self.assertTrue(self.case(HERE, test))

    def test_a_wrapper_that_falls_back_on_any_failure_is_caught(self):
        scripts = self.mutated('install-pin-release.sh', '  3)\n', '  *)\n')
        self.assertFalse(self.case(scripts, 'test_a_checksum_mismatch_fails_and_does_not_fall_back'))

    def test_a_wrapper_that_honours_require_checksum_false_is_caught(self):
        scripts = self.mutated('install-pin-release.sh', ' REPRO_REQUIRE_CHECKSUM=true', '')
        self.assertFalse(self.case(scripts, 'test_require_checksum_false_does_not_reach_this_route'))

    def test_a_manifest_read_in_a_subshell_is_caught(self):
        # skip() inside `$(...)` exits only the subshell; the ERR trap then
        # turns the routine "no archive here" into a hard error.
        scripts = self.mutated('install-release.sh',
                                '    version_from_sums "${sums_path}"\n    version="${SUMS_VERSION}"\n',
                                '    version="$(version_from_sums "${sums_path}"; printf %s "${SUMS_VERSION}")"\n')
        self.assertFalse(self.case(
            scripts, 'test_a_prerelease_without_this_platforms_archive_takes_the_source_route'))

    def test_a_wrapper_asking_reprobuild_instead_of_this_repository_is_caught(self):
        scripts = self.mutated('install-pin-release.sh',
                                ':-metacraft-labs/metacraft-github-actions}', ':-metacraft-labs/reprobuild}')
        self.assertFalse(self.case(scripts, 'test_a_published_prerelease_is_installed_from_this_repository'))

    def test_a_decision_without_the_pin_release_branch_is_caught(self):
        scratch = Path(tempfile.mkdtemp(prefix='repro-pin-mutant-'))
        self.addCleanup(shutil.rmtree, scratch)
        action = ACTION.read_text()
        old = '        elif [ -n "${PIN_RELEASE_BIN_DIR:-}" ]; then\n'
        self.assertEqual(action.count(old), 1)
        (scratch / 'action.yml').write_text(action.replace(old, '        elif false; then\n'))
        result, output = Wiring().decide(scratch / 'action.yml',
                                          PIN_RELEASE_BIN_DIR='C:/t/bin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('install-source=pin-release', output)


if __name__ == '__main__':
    unittest.main()
