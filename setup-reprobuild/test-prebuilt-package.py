"""Admit a caller-built Reprobuild Nix package instead of building another.

A workflow that already builds `github:metacraft-labs/reprobuild/<pin>#reprobuild`
for its own identity receipts hands the store path to `repro-package`, and the
action must then build nothing. It must also accept nothing else: the path has
to be the exact package output the pinned flake evaluates to on this system.

Only `nix` is a stand-in, answering `path-info` and `eval` the way a store that
holds (or lacks) the package would. The real admission script and the real
decision step run under Bash.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SCRIPT = HERE / 'bind-repro-package.sh'
# The commit the action selects by default. The stand-in `nix` only echoes it,
# so any full SHA would do; the pin keeps a second literal revision out of the
# repository.
PIN = json.loads((REPO / 'pins' / 'reprobuild.json').read_text())['rev']
TOKEN = 'ghs_contract_token_never_printed'

STUB_NIX = r'''#!BASH
set -u
# A Nix with a stock nix.conf: the new CLI and flakes are disabled unless the
# command line enables them, so every call must start with that option.
case "${1:-} ${2:-}" in
  "--extra-experimental-features "*nix-command*flakes*|"--extra-experimental-features "*flakes*nix-command*) shift 2 ;;
  *) echo "error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it" >&2; exit 1 ;;
esac
printf '%s\n' "$*" >> "$STUB_LOG"
case "${NIX_CONFIG:-}" in
  *"access-tokens = github.com=$STUB_TOKEN"*) printf 'token-in-config\n' >> "$STUB_LOG" ;;
esac
case "$1" in
  path-info)
    for arg in "$@"; do last="$arg"; done
    [ "$last" = "$STUB_VALID_PATH" ] || { echo "error: path '$last' is not valid" >&2; exit 1; }
    printf '%s\n' "$last" ;;
  eval)
    echo "evaluation warning: 'xxHash' has been renamed to 'xxhash'" >&2
    printf '%s' "$STUB_OUT_PATH" ;;
  *) echo "unexpected nix call: $*" >&2; exit 2 ;;
esac
'''


def step_lines(action, name):
    lines = action.read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_body(action, name):
    lines = step_lines(action, name)
    run = lines.index('      run: |')
    return '\n'.join(
        line[8:] if line.startswith('        ') else ''
        for line in lines[run + 1:]) + '\n'


class PackageAdmission(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='repro-package-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / 'store' / 'h0lwiz8y2sxda454i8acwz6ap1vvjyn6-reprobuild-0.2.24'
        for name in ['bin/repro', 'libexec/reprobuild-nix-daemon']:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\necho "repro 0.2.24"\n')
            path.chmod(0o755)
        tools = self.root / 'tools'
        tools.mkdir()
        bash = shutil.which('bash')
        self.assertIsNotNone(bash)
        (tools / 'nix').write_text(STUB_NIX.replace('BASH', bash, 1))
        (tools / 'nix').chmod(0o755)
        self.log = self.root / 'nix.log'
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('REPRO_', 'GITHUB_', 'GH_TOKEN', 'NIX_CONFIG'))}
        self.env.update(PATH=f'{tools}:{os.environ["PATH"]}', RUNNER_OS='Linux',
                        REPRO_PACKAGE=str(self.package), REPRO_BUILD_PIN=PIN,
                        GH_TOKEN=TOKEN, STUB_TOKEN=TOKEN, STUB_LOG=str(self.log),
                        STUB_VALID_PATH=str(self.package), STUB_OUT_PATH=str(self.package),
                        GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_PATH=str(self.root / 'path'),
                        GITHUB_ENV=str(self.root / 'env'))

    def admit(self, **overrides):
        self.env.update(overrides)
        return subprocess.run(['bash', str(SCRIPT)], env=self.env, text=True,
                              capture_output=True, timeout=20)

    def written(self, name):
        path = self.root / name
        return path.read_text().splitlines() if path.exists() else []

    def nix_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_refused(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('::error::', result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.written('path'), [])
        self.assertEqual(self.written('output'), [])

    def test_the_pinned_package_goes_on_path_without_a_build(self):
        result = self.admit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.written('path'), [f'{self.package}/bin'])
        self.assertIn(f'bin-dir={self.package}/bin', self.written('output'))
        self.assertIn(f'REPROBUILD_NIX_DAEMON_BIN={self.package}/libexec/reprobuild-nix-daemon',
                      self.written('env'))
        calls = self.nix_calls()
        self.assertIn(f'eval --raw --no-update-lock-file '
                      f'github:metacraft-labs/reprobuild/{PIN}#reprobuild.outPath', calls)
        self.assertFalse([c for c in calls if c.startswith(('build', 'develop'))], calls)

    def test_the_token_reaches_nix_only_through_its_configuration(self):
        result = self.admit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('token-in-config', self.nix_calls())
        self.assertFalse([c for c in self.nix_calls() if TOKEN in c])
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        for name in ['path', 'output', 'env']:
            self.assertNotIn(TOKEN, '\n'.join(self.written(name)))

    def test_a_package_of_another_revision_is_refused(self):
        other = self.root / 'store' / 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-reprobuild-0.2.23'
        result = self.admit(STUB_OUT_PATH=str(other))
        self.assert_refused(result, f'github:metacraft-labs/reprobuild/{PIN}#reprobuild')

    def test_a_path_the_store_does_not_hold_is_refused(self):
        result = self.admit(STUB_VALID_PATH='/nix/store/elsewhere')
        self.assert_refused(result, 'not a valid Nix store path')

    def test_a_movable_or_abbreviated_pin_is_refused_before_nix_runs(self):
        for pin in ['dev', 'v0.2.24', PIN[:12], PIN.upper(), '']:
            with self.subTest(pin=pin):
                result = self.admit(REPRO_BUILD_PIN=pin)
                self.assert_refused(result, 'full lowercase commit SHA')
                self.assertEqual(self.nix_calls(), [])

    def test_a_relative_or_multiline_path_is_refused_before_nix_runs(self):
        for path in ['store/x-reprobuild', f'{self.package}\n/tmp/other', f'{self.package}/']:
            with self.subTest(path=path):
                result = self.admit(REPRO_PACKAGE=path)
                self.assert_refused(result, 'repro-package')
                self.assertEqual(self.nix_calls(), [])

    def test_a_package_without_the_cli_or_daemon_helper_is_refused(self):
        for name in ['bin/repro', 'libexec/reprobuild-nix-daemon']:
            with self.subTest(name=name):
                target = self.package / name
                target.chmod(0o644)
                try:
                    self.assert_refused(self.admit(), name)
                finally:
                    target.chmod(0o755)

    def test_windows_is_refused(self):
        result = self.admit(RUNNER_OS='Windows')
        self.assert_refused(result, 'Windows')
        self.assertEqual(self.nix_calls(), [])


class Wiring(unittest.TestCase):
    ACTION = HERE / 'action.yml'

    def decide(self, **values):
        with tempfile.TemporaryDirectory(prefix='repro-package-decide-') as scratch:
            output = Path(scratch) / 'output'
            env = {k: v for k, v in os.environ.items() if not k.startswith(('REPRO_', 'GITHUB_'))}
            env.update(dict(RELEASE_INSTALLED='', RELEASE_BIN_DIR='', RESOLVED_TAG='',
                            REPRO_VERSION='', BUILD_REF=PIN, ORIGIN='pin',
                            REPRO_PACKAGE='', PACKAGE_BIN_DIR='', GITHUB_OUTPUT=str(output)),
                       **values)
            result = subprocess.run(['bash', '-c', step_body(self.ACTION, 'Decide install path')],
                                    env=env, text=True, capture_output=True, timeout=10)
            return result, output.read_text().splitlines() if output.exists() else []

    def test_a_supplied_package_wins_over_the_source_route(self):
        result, output = self.decide(
            REPRO_PACKAGE='/nix/store/p-reprobuild',
            PACKAGE_BIN_DIR='/nix/store/p-reprobuild/bin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=package', output)
        self.assertIn('repro-bin-dir=/nix/store/p-reprobuild/bin', output)
        self.assertIn('need-source=false', output)

    def test_a_package_that_was_not_admitted_fails_closed(self):
        result, output = self.decide(REPRO_PACKAGE='/nix/store/p-reprobuild', PACKAGE_BIN_DIR='')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('need-source=true', output)

    def test_without_a_package_the_source_route_is_unchanged(self):
        result, output = self.decide()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', output)
        self.assertIn('need-source=true', output)

    def test_the_admission_step_precedes_and_excludes_the_other_routes(self):
        source = self.ACTION.read_text()
        self.assertRegex(source, r'(?m)^  repro-package:\n    description:')
        admit = '\n'.join(step_lines(self.ACTION, "Use the caller's prebuilt repro package"))
        self.assertIn("      if: ${{ inputs.repro-package != '' }}", admit)
        self.assertIn('REPRO_PACKAGE: ${{ inputs.repro-package }}', admit)
        # The selected commit: the pin, or the caller's repro-build-pin.
        self.assertIn('REPRO_BUILD_PIN: ${{ steps.pin.outputs.build-ref }}', admit)
        self.assertIn('GH_TOKEN: ${{ inputs.gh-token }}', admit)
        self.assertIn('bind-repro-package.sh', admit)
        release = '\n'.join(step_lines(self.ACTION, 'Install prebuilt repro CLI from GitHub Release'))
        self.assertIn("inputs.repro-package == ''", release)
        decide = '\n'.join(step_lines(self.ACTION, 'Decide install path'))
        self.assertIn('PACKAGE_BIN_DIR: ${{ steps.package.outputs.bin-dir }}', decide)
        order = [source.index('    - name: ' + name) for name in [
            "Use the caller's prebuilt repro package",
            'Install prebuilt repro CLI from GitHub Release',
            'Decide install path', 'Clone reprobuild source']]
        self.assertEqual(order, sorted(order))

    def test_setup_dev_env_forwards_the_package(self):
        parent = REPO / 'setup-dev-env' / 'action.yml'
        source = parent.read_text()
        self.assertRegex(source, r'(?m)^  repro-package:\n    description:')
        step = '\n'.join(step_lines(parent, 'Install the repro CLI (reprobuild)'))
        self.assertIn('        repro-package: ${{ inputs.repro-package }}', step)
        self.assertRegex(step, r'(?m)setup-reprobuild@[0-9a-f]{40}$')


if __name__ == '__main__':
    unittest.main()
