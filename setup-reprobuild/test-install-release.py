"""Exercise the real installer/decision bodies over HTTP and real archives.

Only the SDK executable is a stand-in: SDK runtime qualification belongs to
Reprobuild's real release smoke tests. This suite tests selection, integrity and
error routing, including a misleading ambient CLI; it does not certify a bundle.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile
import threading
import unittest

HERE = Path(__file__).resolve().parent


def step_lines(name):
    lines = (HERE / 'action.yml').read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_body(name):
    lines = step_lines(name)
    run = lines.index('      run: |')
    return '\n'.join(line[8:] if line.startswith('        ') else ''
                    for line in lines[run + 1:]) + '\n'


class ReleaseSelection(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='repro-release-contract-')
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
                status, body = routes.get(handler.path, (404, b'absent'))
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
                    if not k.startswith(('REPRO_', 'GITHUB_', 'GH_TOKEN'))}
        self.env.update(REPRO_RELEASE_DOWNLOAD_ORIGIN=f'http://127.0.0.1:{server.server_port}',
                        REPRO_RELEASE_API_ORIGIN=f'http://127.0.0.1:{server.server_port}',
                        REPRO_INSTALL_DIR=str(self.root / 'installed'),
                        REPRO_VERSION='1.2.3', GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_PATH=str(self.root / 'path'), RUNNER_TEMP=str(self.root))

    def archive(self, reported='1.2.3', corrupt_checksum=False):
        name = f'reprobuild-1.2.3-{self.os_name}-{self.arch}'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            body = f'#!/bin/sh\nprintf "%s\\n" "repro {reported}"\n'.encode()
            entry = tarfile.TarInfo(name + '/bin/repro')
            entry.size, entry.mode = len(body), 0o755
            archive.addfile(entry, io.BytesIO(body))
        payload = data.getvalue()
        asset = name + '.tar.gz'
        prefix = '/metacraft-labs/reprobuild/releases/download/v1.2.3/'
        digest = '0' * 64 if corrupt_checksum else hashlib.sha256(payload).hexdigest()
        self.routes[prefix + 'SHA256SUMS'] = (200, f'{digest}  {asset}\n'.encode())
        self.routes[prefix + asset] = (200, payload)

    def install(self):
        return subprocess.run(['bash', str(HERE / 'install-release.sh')],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def test_parent_forwards_release_and_source_selection_to_published_helper(self):
        # This guards the composite's actual wiring; HTTP tests below exercise
        # the selected child's real installer rather than a replacement SDK.
        parent = (HERE.parent / 'setup-dev-env' / 'action.yml').read_text()
        step = parent.split('    - name: Install the repro CLI (reprobuild)\n', 1)[1]
        step = step.split('    # ------------------------------------------------------------------', 1)[0]
        self.assertRegex(step, r'(?m)^      uses: metacraft-labs/'
                        r'metacraft-github-actions/setup-reprobuild@[0-9a-f]{40}$')
        for child, source in [('repro-version', 'repro-version'),
                              ('repro-build-pin', 'repro-build-pin'),
                              ('from-source', 'repro-from-source')]:
            self.assertIn('        ' + child + ': ${{ inputs.' + source + ' }}\n', step)
        parent_input = re.search(r'^  repro-version:\n(.*?)(?=^  [a-z])',
                                parent, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(parent_input)
        self.assertIn('    default: "latest"\n', parent_input.group(1))

    def test_requested_release_installs_despite_misleading_ambient_cli(self):
        self.archive()
        ambient = self.root / 'ambient'
        ambient.mkdir()
        sentinel = self.root / 'ambient-was-executed'
        cli = ambient / 'repro'
        cli.write_text(f'#!/bin/sh\ntouch "{sentinel}"\necho "repro 1.2.3"\n')
        cli.chmod(0o755)
        self.env['PATH'] = str(ambient) + os.pathsep + self.env['PATH']
        self.env['GITHUB_ACTION_PATH'] = str(HERE)
        body = step_body('Install prebuilt repro CLI from GitHub Release')
        body = body.replace('${{ github.action_path }}', '${GITHUB_ACTION_PATH}')
        result = subprocess.run(['bash', '-c', body], env=self.env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertIn('installed=true', Path(self.env['GITHUB_OUTPUT']).read_text())
        self.assertTrue(self.requests)

    def test_old_already_present_flag_cannot_override_selected_release(self):
        self.env.update(ALREADY_PRESENT='true', RELEASE_INSTALLED='true',
                        RELEASE_BIN_DIR='/selected/package/bin', FROM_SOURCE='false',
                        REPRO_BUILD_PIN='dev')
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text()
        self.assertIn('install-source=release', output)
        self.assertIn('repro-bin-dir=/selected/package/bin', output)
        self.assertNotIn('install-source=path', output)
        self.assertNotIn('steps.probe.outputs', (HERE / 'action.yml').read_text())

    def test_checksum_valid_archive_with_wrong_version_is_hard_failure(self):
        self.archive(reported='9.9.9')
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('requested release v1.2.3', result.stderr)
        self.assertNotIn('REPRO_BIN_DIR=', result.stdout)

    def test_native_crlf_version_record_matches_requested_release(self):
        self.archive(reported='1.2.3\r')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('REPRO_BIN_DIR=', result.stdout)

    def test_checksum_mismatch_is_not_source_fallback(self):
        self.archive(corrupt_checksum=True)
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('checksum MISMATCH', result.stderr)
        self.assertFalse(Path(self.env['REPRO_INSTALL_DIR']).exists())

    def test_missing_asset_retains_source_fallback_status(self):
        result = self.install()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(Path(self.env['REPRO_INSTALL_DIR']).exists())

    def test_explicit_source_route_stays_source(self):
        self.env.update(ALREADY_PRESENT='true', RELEASE_INSTALLED='',
                        RELEASE_BIN_DIR='', FROM_SOURCE='true', REPRO_BUILD_PIN='a' * 40)
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', Path(self.env['GITHUB_OUTPUT']).read_text())
        self.assertIn('from-source=true', result.stdout)

    def test_source_dependency_action_is_guarded_and_ordered(self):
        source = (HERE / 'action.yml').read_text()
        provision = 'Provision selected Reprobuild source dependencies'
        step = '\n'.join(step_lines(provision))
        self.assertIn("      if: ${{ steps.decide.outputs.need-source == 'true' }}", step)
        self.assertRegex(step, r'(?m)^      uses: metacraft-labs/'
                        r'metacraft-github-actions/reprobuild-provision@[0-9a-f]{40}$')
        self.assertLess(source.index('    - name: Clone reprobuild source'), source.index(provision))
        for build in ['Install Nix (Linux/macOS, to build repro)',
                      'Build repro CLI (Linux/macOS)',
                      'Relocate reprobuild + build repro CLI (Windows)',
                      'Build repro CLI (Windows)']:
            self.assertLess(source.index(provision), source.index('    - name: ' + build))

    def test_source_dependency_inputs_preserve_canonical_defaults_and_overrides(self):
        source = (HERE / 'action.yml').read_text()
        canonical = (HERE.parent / 'reprobuild-provision' / 'action.yml').read_text()
        step = '\n'.join(step_lines('Provision selected Reprobuild source dependencies'))
        for name in ['consumer-directory', 'workspace-directory', 'gh-token',
                    'sibling-owner', 'runquota-ref', 'io-mon-ref', 'stackable-hooks-pin']:
            self.assertIn('        ' + name + ': ${{ inputs.' + name + ' }}', step)
            pattern = r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-z]|^outputs:|^runs:)'
            child_input = re.search(pattern, source, re.MULTILINE | re.DOTALL)
            canonical_input = re.search(pattern, canonical, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(child_input, name)
            self.assertIsNotNone(canonical_input, name)
            default = r'^    default: (.*)$'
            self.assertEqual(re.search(default, child_input.group(1), re.MULTILINE).group(1),
                            re.search(default, canonical_input.group(1), re.MULTILINE).group(1), name)

    def test_release_decision_disables_source_dependencies(self):
        self.env.update(RELEASE_INSTALLED='true', RELEASE_BIN_DIR='/selected/package/bin',
                        FROM_SOURCE='false', REPRO_BUILD_PIN='dev')
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('need-source=false', Path(self.env['GITHUB_OUTPUT']).read_text().splitlines())

    def test_real_no_asset_fallback_selects_source_dependencies(self):
        self.assertEqual(self.install().returncode, 3)
        self.env.update(RELEASE_INSTALLED='false', RELEASE_BIN_DIR='',
                        FROM_SOURCE='false', REPRO_BUILD_PIN='dev')
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
        self.assertIn('need-source=true', output)
        self.assertIn('install-source=source', output)
        self.assertIn('FALLING BACK to a source build', result.stdout)

    def test_release_integrity_error_stops_before_source_selection(self):
        self.archive(corrupt_checksum=True)
        self.env['GITHUB_ACTION_PATH'] = str(HERE)
        body = step_body('Install prebuilt repro CLI from GitHub Release')
        body = body.replace('${{ github.action_path }}', '${GITHUB_ACTION_PATH}')
        result = subprocess.run(['bash', '-c', body], env=self.env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Not falling back to a source build', result.stdout)
        self.assertFalse(Path(self.env['GITHUB_OUTPUT']).exists())


if __name__ == '__main__':
    unittest.main()
