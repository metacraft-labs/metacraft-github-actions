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
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

# The Bash that executes install-release.sh. Defaults to the `bash` on PATH;
# set INSTALL_RELEASE_BASH to run the installer cases under another one, such
# as a Bash 3.2 build, without changing anything else the suite runs.
INSTALL_BASH = os.environ.get('INSTALL_RELEASE_BASH') or 'bash'


def find_bash3():
    """Return a Bash 3.x to parse-check with, or (None, reason).

    BASH32 overrides the search and must name a Bash 3.x. Otherwise /bin/bash
    is used when it is one, which it is on stock macOS, whose runners are where
    the action's scripts meet it."""
    override = os.environ.get('BASH32')
    candidates = [override] if override else ['/bin/bash']
    for candidate in candidates:
        if not os.access(candidate, os.X_OK):
            if override:
                raise AssertionError(f'BASH32={override} is not executable')
            continue
        version = subprocess.run(
            [candidate, '-c', 'printf %s "${BASH_VERSINFO[0]}"'],
            text=True, capture_output=True, timeout=10).stdout.strip()
        if version == '3':
            return candidate, None
        if override:
            raise AssertionError(f'BASH32={override} is Bash {version!r}, not 3.x')
    return None, ('no Bash 3.x found: /bin/bash is not one here; set BASH32 '
                  'to a Bash 3.2 build to run this check off macOS')


def repository_shell_scripts():
    listed = subprocess.run(['git', '-C', str(REPO), 'ls-files', '-z', '--', '*.sh'],
                            capture_output=True)
    if listed.returncode == 0:
        names = [n for n in listed.stdout.decode().split('\0') if n]
        return sorted(REPO / n for n in names)
    return sorted(p for p in REPO.rglob('*.sh') if '.git' not in p.parts)


class Bash32Parse(unittest.TestCase):
    """Every shell script must parse under Bash 3.2, the /bin/bash on macOS.

    Bash 3.2's command-substitution parser rejects bodies newer Bash accepts:
    a `while`/`case` loop with comments inside `$(...)` made install-release.sh
    fail on every macOS runner before running a single line, while the Linux
    legs, on Bash 5, stayed green. Only a real 3.x interpreter detects this, so
    the check runs one rather than linting for known shapes."""

    def test_every_shell_script_parses_under_bash_3(self):
        bash3, reason = find_bash3()
        if bash3 is None:
            self.skipTest(reason)
        scripts = repository_shell_scripts()
        self.assertIn(HERE / 'install-release.sh', scripts)
        for script in scripts:
            with self.subTest(script=str(script.relative_to(REPO))):
                result = subprocess.run([bash3, '-n', str(script)], text=True,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)


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

    def archive(self, reported='1.2.3', corrupt_checksum=False, links=()):
        """Publish a release archive; `links` is (path, target) symlinks to add
        under the package root, after any parent directories they need."""
        name = f'reprobuild-1.2.3-{self.os_name}-{self.arch}'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            body = f'#!/bin/sh\nprintf "%s\\n" "repro {reported}"\n'.encode()
            entry = tarfile.TarInfo(name + '/bin/repro')
            entry.size, entry.mode = len(body), 0o755
            archive.addfile(entry, io.BytesIO(body))
            for path, target in links:
                parent = name
                for part in Path(path).parent.parts:
                    parent += '/' + part
                    folder = tarfile.TarInfo(parent)
                    folder.type, folder.mode = tarfile.DIRTYPE, 0o755
                    archive.addfile(folder)
                link = tarfile.TarInfo(f'{name}/{path}')
                link.type, link.linkname = tarfile.SYMTYPE, target
                archive.addfile(link)
        payload = data.getvalue()
        asset = name + '.tar.gz'
        prefix = '/metacraft-labs/reprobuild/releases/download/v1.2.3/'
        digest = '0' * 64 if corrupt_checksum else hashlib.sha256(payload).hexdigest()
        self.routes[prefix + 'SHA256SUMS'] = (200, f'{digest}  {asset}\n'.encode())
        self.routes[prefix + asset] = (200, payload)

    def install(self):
        return subprocess.run([INSTALL_BASH, str(HERE / 'install-release.sh')],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def test_parent_forwards_release_and_source_selection_to_published_helper(self):
        # This guards the composite's actual wiring; HTTP tests below exercise
        # the selected child's real installer rather than a replacement SDK.
        parent = (HERE.parent / 'setup-dev-env' / 'action.yml').read_text()
        step = parent.split('    - name: Install the repro CLI (reprobuild)\n', 1)[1]
        step = step.split('    # ------------------------------------------------------------------', 1)[0]
        self.assertRegex(step, r'(?m)^      uses: metacraft-labs/'
                        r'metacraft-github-actions/setup-reprobuild@[0-9a-f]{40}$')
        # The revision is the parent's own pin selection, never the raw inputs.
        for child, output in [('repro-version', 'release-version'),
                              ('repro-build-pin', 'build-ref'),
                              ('from-source', 'from-source')]:
            self.assertIn('        ' + child + ': ${{ steps.repro-pin.outputs.' + output + ' }}\n', step)
        for child, source in [('sibling-owner', 'token-owner'),
                              ('runquota-ref', 'repro-runquota-pin'),
                              ('io-mon-ref', 'repro-io-mon-pin'),
                              ('stackable-hooks-pin', 'repro-stackable-hooks-pin')]:
            self.assertIn('        ' + child + ': ${{ inputs.' + source + ' }}\n', step)
        parent_input = re.search(r'^  repro-version:\n(.*?)(?=^  [a-z])',
                                parent, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(parent_input)
        self.assertIn('    default: ""\n', parent_input.group(1))
        select = parent.split('    - name: Select the Reprobuild revision (reprobuild)\n', 1)[1]
        select = select.split('    - name: ', 1)[0]
        self.assertIn('../setup-reprobuild/resolve-reprobuild-pin.sh', select)
        for name, source in [('REPRO_VERSION', 'repro-version'),
                              ('REPRO_BUILD_PIN', 'repro-build-pin'),
                              ('FROM_SOURCE', 'repro-from-source')]:
            self.assertIn('        ' + name + ': ${{ inputs.' + source + ' }}\n', select)

    def test_no_revision_default_remains(self):
        # The pin is the only default: no `dev` branch and no `latest`
        # release is chosen when the caller names nothing.
        for manifest in (HERE / 'action.yml', HERE.parent / 'setup-dev-env' / 'action.yml'):
            source = manifest.read_text()
            for name in ('repro-version', 'repro-build-pin'):
                block = re.search(r'^  ' + name + r':\n(.*?)(?=^  [a-z]|^outputs:|^runs:)',
                                  source, re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(block, (manifest, name))
                self.assertIn('    default: ""\n', block.group(1), (manifest, name))
            self.assertNotIn(':-dev}', source, manifest)
            self.assertNotIn(':-latest}', source, manifest)
        self.assertNotIn(':-latest}', (HERE / 'install-release.sh').read_text())

    def test_parent_has_no_unconditional_sdk_dependency_provisioner(self):
        parent = (HERE.parent / 'setup-dev-env' / 'action.yml').read_text()
        self.assertNotRegex(parent, r'(?m)^\s+uses: metacraft-labs/'
                            r'metacraft-github-actions/reprobuild-provision@')
        # Consumer siblings remain independent of SDK source selection.
        self.assertIn('    - name: Clone cross-repo siblings from the workspace lock\n', parent)
        self.assertIn('    - name: Provision cross-repo siblings from the committed repro.lock\n', parent)

    def test_windows_preparation_preserves_consumer_and_selected_source(self):
        for collision in (False, True):
            with self.subTest(existing_consumer=collision):
                workspace = self.root / ('collision' if collision else 'empty')
                selected = workspace / '.reprobuild-src'
                (selected / 'apps').mkdir(parents=True)
                entrypoints = selected / 'apps' / 'entrypoints.txt'
                entrypoints.write_bytes(b'selected-sdk\r\n')
                consumer = workspace / 'reprobuild'
                if collision:
                    (consumer / 'apps').mkdir(parents=True)
                    (consumer / 'apps' / 'entrypoints.txt').write_bytes(b'consumer\r\n')
                env = dict(self.env, MCL_WORKSPACE_ROOT=str(workspace))
                result = subprocess.run(
                    ['bash', '-c', step_body('Prepare selected reprobuild source (Windows)')],
                    env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(selected.is_dir())
                self.assertEqual(entrypoints.read_bytes(), b'selected-sdk\n')
                if collision:
                    self.assertEqual((consumer / 'apps' / 'entrypoints.txt').read_bytes(),
                                      b'consumer\r\n')
                else:
                    self.assertFalse(consumer.exists())
        # The real PowerShell constructor must consume the same selected tree.
        build = step_body('Build repro CLI (Windows)')
        self.assertIn('Set-Location "$env:MCL_WORKSPACE_ROOT\\.reprobuild-src"', build)
        self.assertNotIn('Set-Location "$env:MCL_WORKSPACE_ROOT\\reprobuild"', build)

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
                        RELEASE_BIN_DIR='/selected/package/bin', BUILD_REF='a' * 40)
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

    def test_relative_symlink_inside_the_package_installs(self):
        # The shape of the darwin non-SIP tools bundle: usr/bin/<tool> links
        # climb with `..` but resolve to bin/<tool> inside the same bundle.
        self.archive(links=[('libexec/tools/bin/tee', '../../../bin/repro'),
                            ('libexec/tools/usr/bin/tee', '../../bin/tee')])
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('REPRO_BIN_DIR=', result.stdout)

    def test_relative_symlink_escaping_the_package_is_refused(self):
        self.archive(links=[('libexec/out', '../../../etc/passwd')])
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('pointing outside the package', result.stderr)
        self.assertFalse(Path(self.env['REPRO_INSTALL_DIR']).exists())

    def test_absolute_symlink_is_refused(self):
        self.archive(links=[('bin/host-sh', '/bin/sh')])
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('pointing outside the package', result.stderr)

    def test_symlink_to_the_parent_of_the_package_is_refused(self):
        self.archive(links=[('up', '..')])
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('pointing outside the package', result.stderr)

    def test_trailing_slash_symlink_escaping_the_package_is_refused(self):
        # `dirname "../"` is `.`: without stripping the slash first, only the
        # link's own directory would be judged.
        for target in ('../', '..//', 'bin/../../'):
            with self.subTest(target=target):
                self.archive(links=[('up', target)])
                result = self.install()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('pointing outside the package', result.stderr)
        self.archive(links=[('libexec/out', '../../')])
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_trailing_slash_symlink_inside_the_package_installs(self):
        self.archive(links=[('libexec/tools/bindir', '../../bin/')])
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checksum_mismatch_is_not_source_fallback(self):
        self.archive(corrupt_checksum=True)
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('checksum MISMATCH', result.stderr)
        self.assertFalse(Path(self.env['REPRO_INSTALL_DIR']).exists())

    def test_an_unnamed_release_is_refused_not_resolved_as_latest(self):
        self.env.pop('REPRO_VERSION')
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('names no release', result.stderr)
        self.assertNotIn('/releases/latest', self.requests)

    def test_missing_asset_retains_source_fallback_status(self):
        result = self.install()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(Path(self.env['REPRO_INSTALL_DIR']).exists())

    def test_windows_on_arm_selects_the_machine_not_the_emulated_bash(self):
        # Git Bash answers `uname -m` with x86_64 on Windows on ARM: it runs
        # emulated. The runner's RUNNER_ARCH names the machine.
        shim = self.root / 'uname-shim'
        shim.mkdir()
        (shim / 'uname').write_text('#!/bin/sh\n'
                                    'case "$1" in -s) echo MINGW64_NT-10.0-26100 ;;'
                                    ' -m) echo x86_64 ;; esac\n')
        (shim / 'uname').chmod(0o755)
        prefix = '/metacraft-labs/reprobuild/releases/download/v1.2.3/'
        for runner_arch, arch in (('ARM64', 'aarch64'), ('X64', 'x86_64'), (None, 'x86_64')):
            with self.subTest(runner_arch=runner_arch):
                env = dict(self.env, PATH=f'{shim}{os.pathsep}{self.env["PATH"]}')
                env.pop('RUNNER_ARCH', None)
                if runner_arch:
                    env['RUNNER_ARCH'] = runner_arch
                self.routes[prefix + 'SHA256SUMS'] = (200, b'')
                self.requests.clear()
                result = subprocess.run([INSTALL_BASH, str(HERE / 'install-release.sh')],
                                        env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn(f'reprobuild-1.2.3-windows-{arch}.zip', result.stdout + result.stderr)

    def test_missing_asset_still_reports_the_resolved_release(self):
        # No asset for this platform (the linux-aarch64 case): the script skips
        # with exit 3 but names the release it resolved, so the source fallback
        # can build that tag instead of a moving branch.
        result = self.install()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('REPRO_RESOLVED_TAG=v1.2.3', result.stdout.splitlines())

    def test_installed_release_reports_tag_and_keeps_bin_dir_last(self):
        self.archive()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn('REPRO_RESOLVED_TAG=v1.2.3', lines)
        self.assertTrue(lines[-1].startswith('REPRO_BIN_DIR='), lines)

    def test_source_fallback_builds_the_selected_ref_else_the_resolved_release(self):
        # The selected ref wins, then the release this run resolved. With
        # neither there is nothing to build: no branch default.
        base = dict(RELEASE_INSTALLED='false', RELEASE_BIN_DIR='', REPRO_VERSION='latest')
        cases = (
            ('', 'v0.2.26', "'v0.2.26'"),
            ('a' * 40, 'v0.2.26', "'" + 'a' * 40 + "'"),
        )
        for ref, tag, expected in cases:
            with self.subTest(ref=ref, tag=tag):
                self.env.update(base, BUILD_REF=ref, RESOLVED_TAG=tag)
                result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                        env=self.env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('source build of ' + expected, result.stdout)
        self.env.update(base, BUILD_REF='', RESOLVED_TAG='',
                        GITHUB_OUTPUT=str(self.root / 'refused-output'))
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('no revision was selected to build', result.stdout)
        self.assertFalse(Path(self.env['GITHUB_OUTPUT']).exists())
        clone = step_body('Clone reprobuild source')
        self.assertIn('REF="${BUILD_REF:-${RESOLVED_TAG:-}}"', clone)
        for step in ('Decide install path', 'Clone reprobuild source'):
            self.assertIn('BUILD_REF: ${{ steps.pin.outputs.build-ref }}',
                          '\n'.join(step_lines(step)))

    def test_selected_source_route_stays_source(self):
        # A pinned commit selects no release; the build is the route, not a
        # fallback, so it is a notice and not a warning.
        self.env.update(RELEASE_INSTALLED='', RELEASE_BIN_DIR='', REPRO_VERSION='',
                        BUILD_REF='a' * 40, ORIGIN='pin')
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', Path(self.env['GITHUB_OUTPUT']).read_text())
        self.assertIn('::notice::setup-reprobuild: building repro from source at '
                      + 'a' * 40 + ' (pin)', result.stdout)
        self.assertNotIn('::warning::', result.stdout)

    def test_every_route_reads_the_selection_not_the_raw_inputs(self):
        source = (HERE / 'action.yml').read_text()
        self.assertLess(source.index('    - name: Select the Reprobuild revision\n'),
                        source.index('    - name: Use the caller\'s prebuilt repro package\n'))
        release = '\n'.join(step_lines('Install prebuilt repro CLI from GitHub Release'))
        self.assertIn("if: ${{ steps.pin.outputs.release-version != '' && inputs.repro-package == '' }}", release)
        self.assertIn('REPRO_VERSION: ${{ steps.pin.outputs.release-version }}', release)
        package = '\n'.join(step_lines("Use the caller's prebuilt repro package"))
        self.assertIn('REPRO_BUILD_PIN: ${{ steps.pin.outputs.build-ref }}', package)
        for step in ('Install prebuilt repro CLI from GitHub Release', 'Decide install path',
                      'Clone reprobuild source', "Use the caller's prebuilt repro package"):
            body = '\n'.join(step_lines(step))
            self.assertNotIn('inputs.repro-build-pin', body, step)
            self.assertNotIn('inputs.repro-version', body, step)
        check = '\n'.join(step_lines('Check the installed repro is the selected one'))
        self.assertIn('check-installed-repro.sh', check)
        self.assertGreater(source.index('    - name: Check the installed repro is the selected one'),
                            source.index('    - name: Build repro CLI (Windows)'))

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
                      'Prepare selected reprobuild source (Windows)',
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

    def test_source_dependencies_follow_the_cloned_reprobuild_lock(self):
        # The provisioner reads flake.lock from the checkout the source build
        # clones, so its siblings default to what repro-build-pin locks, not
        # to a mainline that may lack modules that lock's RunQuota has.
        source = (HERE / 'action.yml').read_text()
        step = '\n'.join(step_lines('Provision selected Reprobuild source dependencies'))
        self.assertIn('        reprobuild-source-directory: '
                      '${{ steps.roots.outputs.workspace-directory }}/.reprobuild-src', step)
        clone = '\n'.join(step_lines('Clone reprobuild source'))
        self.assertIn('DEST="${MCL_WORKSPACE_ROOT}/.reprobuild-src"', clone)
        self.assertIn('MCL_WORKSPACE_ROOT: ${{ steps.roots.outputs.workspace-directory }}', clone)
        for name in ['runquota-ref', 'io-mon-ref', 'stackable-hooks-pin']:
            child_input = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-z])',
                                    source, re.MULTILINE | re.DOTALL)
            self.assertIn('    default: ""\n', child_input.group(1), name)

    def test_release_decision_disables_source_dependencies(self):
        self.env.update(RELEASE_INSTALLED='true', RELEASE_BIN_DIR='/selected/package/bin',
                        BUILD_REF='a' * 40)
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('need-source=false', Path(self.env['GITHUB_OUTPUT']).read_text().splitlines())

    def test_real_no_asset_fallback_selects_source_dependencies(self):
        self.assertEqual(self.install().returncode, 3)
        self.env.update(RELEASE_INSTALLED='false', RELEASE_BIN_DIR='',
                        BUILD_REF='a' * 40)
        result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
        self.assertIn('need-source=true', output)
        self.assertIn('install-source=source', output)
        self.assertIn('FALLING BACK to a source build', result.stdout)

    def run_release_step_with_only_bash(self, stdout, status):
        """Run the release step the way a self-hosted runner does when its PATH
        is a Nix profile without coreutils: only `bash` resolves.

        The installer itself puts the system directories back on its own PATH,
        so its real behaviour is captured first (by the caller) under the
        ambient PATH and replayed here by a stand-in that uses only `printf`.
        The stand-in is the only substitution: the step body is the real one."""
        bash = shutil.which('bash')
        self.assertIsNotNone(bash)
        only_bash = self.root / 'only-bash'
        only_bash.mkdir()
        (only_bash / 'bash').symlink_to(bash)
        replay = self.root / 'replay-action'
        replay.mkdir()
        lines = ' '.join(shlex.quote(line) for line in stdout.splitlines())
        (replay / 'install-release.sh').write_text(
            f"printf '%s\\n' {lines}\nexit {status}\n")
        body = step_body('Install prebuilt repro CLI from GitHub Release')
        body = body.replace('${{ github.action_path }}', '${GITHUB_ACTION_PATH}')
        env = dict(self.env, PATH=str(only_bash), GITHUB_ACTION_PATH=str(replay))
        # The runner's own invocation of a `shell: bash` step.
        argv = [bash, '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', body]
        return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)

    def test_release_step_parses_the_tag_with_bash_builtins_only(self):
        # mcl-bench-001 (macOS): the step exited 127 on `sed: command not found`
        # right after a verified install, because its PATH had no sed.
        self.archive()
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        result = self.run_release_step_with_only_bash(installed.stdout, 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('command not found', result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
        self.assertIn('resolved-tag=v1.2.3', output)
        self.assertIn('installed=true', output)
        bin_dir = str(Path(self.env['REPRO_INSTALL_DIR']) / 'bin')
        self.assertIn('bin-dir=' + bin_dir, output)
        self.assertEqual(Path(self.env['GITHUB_PATH']).read_text().splitlines(), [bin_dir])

    def test_release_step_reports_the_tag_without_coreutils_on_fallback(self):
        skipped = self.install()
        self.assertEqual(skipped.returncode, 3, skipped.stderr)
        result = self.run_release_step_with_only_bash(skipped.stdout, 3)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
        self.assertEqual(output, ['resolved-tag=v1.2.3', 'installed=false'])

    def test_release_step_keeps_the_last_tag_and_rejects_non_tags(self):
        cases = (
            ('REPRO_RESOLVED_TAG=v1.0.0\nnoise\nREPRO_RESOLVED_TAG=v1.2.3\n', 'v1.2.3'),
            ('xREPRO_RESOLVED_TAG=v9.9.9\n', ''),
            ('REPRO_RESOLVED_TAG=dev\n', ''),
            ('REPRO_RESOLVED_TAG=v1.2.3$(id)\n', ''),
            ('', ''),
        )
        for index, (stdout, expected) in enumerate(cases):
            with self.subTest(stdout=stdout):
                self.root = Path(self.temporary.name) / f'case-{index}'
                self.root.mkdir()
                self.env['GITHUB_OUTPUT'] = str(self.root / 'output')
                result = self.run_release_step_with_only_bash(stdout, 3)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
                self.assertEqual(output, ['resolved-tag=' + expected, 'installed=false'])

    def test_explicit_roots_resolve_with_only_bash_and_git_on_path(self):
        # ci-roots/route.sh runs before any tool provisioning. With explicit
        # roots it locates resolve.sh beside itself, which used `dirname`.
        bash, git = shutil.which('bash'), shutil.which('git')
        self.assertIsNotNone(bash)
        self.assertIsNotNone(git)
        tools = self.root / 'bash-and-git'
        tools.mkdir()
        (tools / 'bash').symlink_to(bash)
        (tools / 'git').symlink_to(git)
        workspace = self.root / 'workspace'
        consumer = workspace / 'consumer'
        consumer.mkdir(parents=True)
        quiet = dict(capture_output=True, text=True, check=True, timeout=10)
        subprocess.run([git, 'init', '-q', str(consumer)], **quiet)
        subprocess.run([git, '-C', str(consumer), '-c', 'user.name=t', '-c', 'user.email=t@t',
                        'commit', '-q', '--allow-empty', '-m', 'init'], **quiet)
        rev_parse = [git, '-C', str(consumer), 'rev-parse', 'HEAD']
        head = subprocess.run(rev_parse, **quiet).stdout.strip()
        workspace = workspace.resolve()
        env = dict(self.env, PATH=str(tools), GITHUB_ACTION_PATH=str(HERE))
        env.update(GITHUB_WORKSPACE=str(workspace), GITHUB_SHA=head)
        env.update(MCL_CONSUMER_DIRECTORY='consumer', MCL_WORKSPACE_DIRECTORY='.')
        body = step_body('Resolve explicit checkout and SDK roots')
        argv = [bash, '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', body]
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(self.env['GITHUB_OUTPUT']).read_text().splitlines()
        self.assertEqual(output, ['workspace-directory=' + str(workspace),
                                  'legacy-layout=false'])

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
