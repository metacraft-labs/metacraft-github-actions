#!/usr/bin/env python3
"""Controls for tools/check-reprobuild-fits-workspace.sh.

Needs a real `repro` and a real repro-workspace checkout, so it runs where the
`pins` workflow has both (the reprobuild-package job) or by hand:

  tools/test-check-reprobuild-fits-workspace.py --repro <repro> --workspace <checkout>

Each case clones the given checkout into a temporary directory and runs the
real script against the clone, so the checkout itself is never written. The
negative controls show that the check notices a manifest the binary cannot
read: a project manifest with a key no `repro` knows, and a repo fragment that
is not TOML.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'tools' / 'check-reprobuild-fits-workspace.sh'
ARGS = None


class FitsWorkspace(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='fits-workspace-')
        self.addCleanup(temporary.cleanup)
        self.clone = Path(temporary.name) / 'workspace'
        subprocess.run(['git', 'clone', '-q', '--no-hardlinks', ARGS.workspace, str(self.clone)],
                        check=True, capture_output=True)

    def check(self):
        return subprocess.run(['bash', str(SCRIPT), ARGS.repro, str(self.clone)],
                              capture_output=True, text=True, timeout=900)

    def test_the_workspace_fits(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ok   repro answers the managed-hook contract', result.stdout)

    def test_an_unknown_project_manifest_key_fails(self):
        project = sorted((self.clone / 'projects').glob('*.toml'))[0]
        lines = project.read_text().splitlines(keepends=True)
        # After the first line (`schema = ...`), before any table.
        project.write_text(lines[0] + 'stp1_negative_control_key = [1]\n' + ''.join(lines[1:]))
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('stp1_negative_control_key', result.stdout)
        self.assertIn('FAIL ', result.stdout)

    def test_a_broken_repo_fragment_fails(self):
        fragment = sorted((self.clone / 'repos').glob('*.toml'))[0]
        fragment.write_text(fragment.read_text() + '\n[[[ not toml\n')
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAIL ', result.stdout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--repro', required=True)
    parser.add_argument('--workspace', required=True)
    ARGS, rest = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0]] + rest)
