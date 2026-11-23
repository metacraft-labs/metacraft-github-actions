#!/usr/bin/env python3
"""Tests of tools/workspace-manifest-branches.py: which repro-workspace
branches section 0b of the pins workflow checks.

Runs the real script as a subprocess on `git ls-remote --heads` text, so the
exit status and the GITHUB_OUTPUT lines the workflow reads are what is tested.
"""
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parent / 'workspace-manifest-branches.py'


def ls_remote(*refs):
    return ''.join(f'{index:040x}\t{ref}\n' for index, ref in enumerate(refs, 1))


def run(text):
    return subprocess.run([sys.executable, '-I', str(SCRIPT)], input=text,
                          capture_output=True, text=True, timeout=60)


def outputs(result):
    return dict(line.split('=', 1) for line in result.stdout.splitlines())


class Selection(unittest.TestCase):
    def assertSelects(self, text, branches):
        result = run(text)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = outputs(result)
        self.assertEqual(values['branches'], ' '.join(branches))
        for name in ('latest', 'dev', 'agents'):
            self.assertEqual(values[name], 'true' if name in branches else 'false', name)
        return result

    def test_all_three_are_checked_mainline_first(self):
        result = self.assertSelects(
            ls_remote('refs/heads/agents', 'refs/heads/dev', 'refs/heads/latest'),
            ['latest', 'dev', 'agents'])
        self.assertIn('checked: latest dev agents', result.stderr)
        self.assertIn('absent:  (none)', result.stderr)

    def test_the_migration_state_without_agents(self):
        # repro-workspace on 2026-11-23: `dev` and `latest`, `agents` retired.
        result = self.assertSelects(
            ls_remote('refs/heads/dev', 'refs/heads/latest'), ['latest', 'dev'])
        self.assertIn('absent:  agents', result.stderr)

    def test_after_the_migration_latest_alone(self):
        result = self.assertSelects(ls_remote('refs/heads/latest'), ['latest'])
        self.assertIn('absent:  dev agents', result.stderr)

    def test_other_refs_are_ignored(self):
        self.assertSelects(
            ls_remote('refs/heads/latest', 'refs/heads/latest-old', 'refs/heads/feature/dev',
                      'refs/tags/agents', 'refs/heads/agents-to-dev-2026-11-01'),
            ['latest'])

    def test_sha256_object_names_are_read(self):
        result = run(f"{'a' * 64}\trefs/heads/latest\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs(result)['branches'], 'latest')

    def test_without_latest_it_fails_even_when_others_exist(self):
        result = run(ls_remote('refs/heads/dev', 'refs/heads/agents'))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('no `latest`', result.stderr)
        self.assertNotIn('branches=', result.stdout)

    def test_none_of_them_fails(self):
        for text in ('', ls_remote('refs/heads/main', 'refs/heads/feature')):
            with self.subTest(text=text):
                result = run(text)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('would check nothing', result.stderr)
                self.assertEqual(result.stdout, '')

    def test_input_that_is_not_ls_remote_output_is_a_usage_error(self):
        garbage = (
            'fatal: could not read Username\n',
            'latest\ndev\n',
            f"{'0' * 40} refs/heads/latest\n",
        )
        for text in garbage:
            with self.subTest(text=text):
                result = run(text)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
