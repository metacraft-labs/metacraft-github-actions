"""Substitute the selected commit's Reprobuild package from a binary cache.

The pinned commit is built once and pushed to the organisation's cache; every
later Linux job should download it rather than compile the engine again. The
action must ask the cache without ever building (a miss must fall back to the
source route, not turn into a slower Nix build), must admit only the package
the pinned flake evaluates to, and must keep the source route for every
selection the package does not stand for.

Only `nix` is a stand-in. It answers `build` the way a Nix whose substituters
hold (or lack) the package does, and `path-info` / `eval` the way its store
does afterwards; the real script, the real admission script and the real
decision step run under Bash. The same script was also run against a real
Nix and the real cache; that is recorded in the change, not here, because CI
has no credential for the private cache.
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
SCRIPT = HERE / 'substitute-repro-package.sh'
ACTION = HERE / 'action.yml'
PIN = json.loads((REPO / 'pins' / 'reprobuild.json').read_text())['rev']
TOKEN = 'ghs_contract_token_never_printed'

STUB_NIX = r'''#!BASH
set -u
case "${1:-} ${2:-}" in
  "--extra-experimental-features "*nix-command*flakes*) shift 2 ;;
  *) echo "error: experimental Nix feature 'nix-command' is disabled" >&2; exit 1 ;;
esac
printf '%s\n' "$*" >> "$STUB_LOG"
case "${NIX_CONFIG:-}" in
  *"access-tokens = github.com=$STUB_TOKEN"*) printf 'token-in-config\n' >> "$STUB_LOG" ;;
esac
case "$1" in
  build)
    case " $* " in *" --max-jobs 0 "*) ;; *) echo "stub: a build without --max-jobs 0" >&2; exit 9 ;; esac
    # max-jobs 0 still lets Nix hand the build to remote builders; only an
    # empty builders list makes a miss a refusal on a host that names some.
    case " $* " in *" --builders  "*) ;; *) echo "stub: a build that may use remote builders" >&2; exit 9 ;; esac
    case "$STUB_CACHE" in
      hit) printf '%s\n' "$STUB_OUT_PATH" ;;
      miss)
        # Nix 2.34's wording, recorded from a real run against the pin.
        printf '%s\n' "evaluation warning: 'xxHash' has been renamed to 'xxhash'" \
          'this derivation will be built:' \
          '  /nix/store/64xj3lb05k0j38fm1v2x1fl4fkrmwacw-reprobuild-0.2.34.drv' \
          "error: Cannot build '/nix/store/64xj3lb05k0j38fm1v2x1fl4fkrmwacw-reprobuild-0.2.34.drv'." \
          '       Reason: local builds are disabled (max-jobs = 0)' \
          "       Hint: set 'max-jobs' to a non-zero value to enable local builds, or configure remote builders via 'builders'" >&2
        exit 1 ;;
      miss-old)
        echo "error: unable to start any build; either increase '--max-jobs' or enable remote builds." >&2
        exit 1 ;;
      unreachable)
        # The cache answers 401, Nix disables it, then refuses the build.
        echo "warning: unable to download 'https://cache.example/x.narinfo': HTTP error 401" >&2
        echo "warning: substituter 'https://cache.example' is disabled" >&2
        echo "error: Cannot build '/nix/store/x-reprobuild.drv'." >&2
        echo "       Reason: local builds are disabled (max-jobs = 0)" >&2
        exit 1 ;;
      broken)
        echo "error: cannot fetch input 'github:metacraft-labs/runquota': HTTP error 404" >&2
        exit 1 ;;
    esac ;;
  path-info)
    for arg in "$@"; do last="$arg"; done
    [ "$last" = "$STUB_VALID_PATH" ] || { echo "error: path '$last' is not valid" >&2; exit 1; }
    printf '%s\n' "$last" ;;
  eval) printf '%s' "$STUB_EVAL_PATH" ;;
  *) echo "unexpected nix call: $*" >&2; exit 2 ;;
esac
'''


def step_lines(name):
    lines = ACTION.read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_body(name):
    lines = step_lines(name)
    run = lines.index('      run: |')
    return '\n'.join(
        line[8:] if line.startswith('        ') else ''
        for line in lines[run + 1:]) + '\n'


def condition(name):
    return next(line for line in step_lines(name) if line.startswith('      if: '))


class Substitution(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='repro-cache-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / 'store' / '4dafr4w8dwj1la99yamqg3zlv1cn7byf-reprobuild-0.2.34'
        for name in ['bin/repro', 'libexec/reprobuild-nix-daemon']:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\necho "repro 0.2.34"\n')
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
                        RUNNER_TEMP=str(self.root), REPRO_BUILD_PIN=PIN,
                        GH_TOKEN=TOKEN, STUB_TOKEN=TOKEN, STUB_LOG=str(self.log),
                        STUB_CACHE='hit', STUB_OUT_PATH=str(self.package),
                        STUB_VALID_PATH=str(self.package), STUB_EVAL_PATH=str(self.package),
                        GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_PATH=str(self.root / 'path'),
                        GITHUB_ENV=str(self.root / 'env'))

    def run_script(self, **overrides):
        self.env.update(overrides)
        return subprocess.run(['bash', str(SCRIPT)], env=self.env, text=True,
                              capture_output=True, timeout=20)

    def written(self, name):
        path = self.root / name
        return path.read_text().splitlines() if path.exists() else []

    def nix_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_source_route(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.written('path'), [])
        self.assertEqual(self.written('output'), [])
        self.assertEqual(self.written('env'), [])

    def test_a_cached_package_is_substituted_and_admitted(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.written('path'), [f'{self.package}/bin'])
        self.assertIn(f'bin-dir={self.package}/bin', self.written('output'))
        self.assertIn(f'REPROBUILD_NIX_DAEMON_BIN={self.package}/libexec/reprobuild-nix-daemon',
                      self.written('env'))
        builds = [c for c in self.nix_calls() if c.startswith('build ')]
        self.assertEqual(builds, [
            'build --no-link --print-out-paths --no-update-lock-file --max-jobs 0 --builders  '
            f'github:metacraft-labs/reprobuild/{PIN}#reprobuild'])

    def test_a_cache_miss_takes_the_source_route_without_building(self):
        for wording in ['miss', 'miss-old']:
            with self.subTest(wording=wording):
                self.log.unlink(missing_ok=True)
                result = self.run_script(STUB_CACHE=wording)
                self.assert_source_route(result)
                self.assertIn('::notice::', result.stdout)
                self.assertNotIn('::warning::', result.stdout)
                self.assertIn('no configured binary cache holds', result.stdout)
                # Asked once, and never evaluated for admission.
                self.assertEqual(
                    [c.split()[0] for c in self.nix_calls() if c != 'token-in-config'],
                    ['build'])

    def test_an_unreachable_cache_is_not_reported_as_a_miss(self):
        for failure, detail in [('unreachable', 'is disabled'), ('broken', 'HTTP error 404')]:
            with self.subTest(failure=failure):
                result = self.run_script(STUB_CACHE=failure)
                self.assert_source_route(result)
                self.assertIn('::warning::', result.stdout)
                self.assertNotIn('::notice::', result.stdout)
                self.assertIn(detail, result.stdout)

    def test_a_substituted_package_of_another_revision_fails_closed(self):
        other = self.root / 'store' / 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-reprobuild-0.2.33'
        result = self.run_script(STUB_EVAL_PATH=str(other))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('::error::', result.stderr)
        self.assertEqual(self.written('path'), [])
        self.assertEqual(self.written('output'), [])

    def test_a_movable_or_abbreviated_revision_never_reaches_nix(self):
        for pin in ['dev', 'v0.2.34', PIN[:12], PIN.upper(), '']:
            with self.subTest(pin=pin):
                result = self.run_script(REPRO_BUILD_PIN=pin)
                self.assert_source_route(result)
                self.assertEqual(self.nix_calls(), [])

    def test_without_nix_the_source_route_runs(self):
        empty = self.root / 'empty-path'
        empty.mkdir()
        result = subprocess.run([shutil.which('bash'), str(SCRIPT)],
                                env={**self.env, 'PATH': str(empty)}, text=True,
                                capture_output=True, timeout=20)
        self.assert_source_route(result)
        self.assertIn('no nix on PATH', result.stdout)

    def test_the_token_reaches_nix_only_through_its_configuration(self):
        for cache in ['hit', 'miss', 'unreachable', 'broken']:
            with self.subTest(cache=cache):
                self.log.unlink(missing_ok=True)
                result = self.run_script(STUB_CACHE=cache)
                self.assertIn('token-in-config', self.nix_calls())
                self.assertFalse([c for c in self.nix_calls() if TOKEN in c])
                self.assertNotIn(TOKEN, result.stdout + result.stderr)
                for name in ['path', 'output', 'env']:
                    self.assertNotIn(TOKEN, '\n'.join(self.written(name)))

    def test_windows_is_refused(self):
        result = self.run_script(RUNNER_OS='Windows')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.nix_calls(), [])


class Wiring(unittest.TestCase):
    NIX = 'Install Nix (Linux, to substitute the selected repro package)'
    CACHE = 'Substitute the selected repro package from the binary cache'

    def decide(self, **values):
        with tempfile.TemporaryDirectory(prefix='repro-cache-decide-') as scratch:
            output = Path(scratch) / 'output'
            env = {k: v for k, v in os.environ.items() if not k.startswith(('REPRO_', 'GITHUB_'))}
            env.update(dict(RELEASE_INSTALLED='', RELEASE_BIN_DIR='', RESOLVED_TAG='',
                            REPRO_VERSION='', BUILD_REF=PIN, ORIGIN='pin',
                            REPRO_PACKAGE='', PACKAGE_BIN_DIR='', CACHE_BIN_DIR='',
                            GITHUB_OUTPUT=str(output)), **values)
            result = subprocess.run(['bash', '-c', step_body('Decide install path')],
                                    env=env, text=True, capture_output=True, timeout=10)
            return result, output.read_text().splitlines() if output.exists() else []

    def test_a_substituted_package_replaces_the_source_build(self):
        result, output = self.decide(CACHE_BIN_DIR='/nix/store/c-reprobuild/bin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=cache', output)
        self.assertIn('repro-bin-dir=/nix/store/c-reprobuild/bin', output)
        self.assertIn('need-source=false', output)

    def test_a_miss_leaves_the_source_route_unchanged(self):
        result, output = self.decide()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-source=source', output)
        self.assertIn('need-source=true', output)

    def test_both_steps_run_only_for_a_linux_source_selection_of_a_commit(self):
        for name in [self.NIX, self.CACHE]:
            with self.subTest(step=name):
                test = condition(name)
                self.assertIn("runner.os == 'Linux'", test)
                # A caller's package or a release is installed instead.
                self.assertIn("inputs.repro-package == ''", test)
                self.assertIn("steps.pin.outputs.release-version == ''", test)
                # Only a full SHA names one package.
                self.assertIn("steps.pin.outputs.expected-commit != ''", test)
                # These build a different engine than the flake package.
                self.assertIn("inputs.io-mon-pin == ''", test)
                self.assertIn("inputs.runquota-ref == ''", test)
        self.assertEqual(condition(self.NIX), condition(self.CACHE))

    def test_the_cache_step_asks_for_the_selected_commit(self):
        step = '\n'.join(step_lines(self.CACHE))
        self.assertIn('REPRO_BUILD_PIN: ${{ steps.pin.outputs.expected-commit }}', step)
        self.assertIn('GH_TOKEN: ${{ inputs.gh-token }}', step)
        self.assertIn('substitute-repro-package.sh', step)
        nix = '\n'.join(step_lines(self.NIX))
        names = [
            'gh-token', 'substituters', 'trusted-public-keys',
            'attic-token', 'attic-cache', 'attic-endpoint',
        ]
        for name in names:
            self.assertIn(f'        {name}: ${{{{ inputs.{name} }}}}', nix)

    def test_the_steps_sit_between_the_installers_and_the_decision(self):
        source = ACTION.read_text()
        order = [source.index('    - name: ' + name) for name in [
            'Install prebuilt repro CLI from GitHub Release', self.NIX, self.CACHE,
            'Decide install path', 'Clone reprobuild source',
            'Install Nix (Linux/macOS, to build repro)']]
        self.assertEqual(order, sorted(order))
        decide = '\n'.join(step_lines('Decide install path'))
        self.assertIn('CACHE_BIN_DIR: ${{ steps.cache.outputs.bin-dir }}', decide)

    def test_nix_is_installed_once_on_a_miss(self):
        later = condition('Install Nix (Linux/macOS, to build repro)')
        self.assertIn("steps.cache-nix.outcome != 'success'", later)
        self.assertIn('      id: cache-nix', '\n'.join(step_lines(self.NIX)))

    def test_the_commit_output_names_the_substituted_commit(self):
        source = ACTION.read_text()
        self.assertIn("steps.decide.outputs.install-source == 'cache'", source)


if __name__ == '__main__':
    unittest.main()
