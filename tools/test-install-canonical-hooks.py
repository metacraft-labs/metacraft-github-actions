#!/usr/bin/env python3
"""Exercise real generated managed hooks with an explicitly selected engine.

No mock hooks, SDK images or subprocess adapters: every case starts with a real
Git repository and the selected Repro engine's canonical hooks. Negative cases
then damage only that owned hook input. Run inside the owning native SDK with
`python3 tools/test-install-canonical-hooks.py --repro /absolute/path/to/repro`.
This tests the body handshake, not native Windows or installed SDK completeness.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repro", required=True)
args, remaining = parser.parse_known_args()
REPRO = Path(args.repro).absolute()
# Import the production helper without adding generated files to its checkout.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "canonical_hooks", Path(__file__).with_name("install-canonical-hooks.py")
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class GeneratedContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="actions-hook-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        subprocess.run(
            [str(REPRO), "hooks", "ensure", "--vcs", str(self.root)],
            cwd=self.root, check=True, capture_output=True,
        )
        self.hooks = self.root / ".git/hooks"
        self.managed = self.hooks / "pre-commit.repro-managed"
        self.original = self.managed.read_text()
        self.token = re.findall(r"--hook-contract=([^\s\"']+)", self.original)[0]

    def test_selected_engine_accepts_its_actual_generated_contract(self):
        installer.require_generated_contract(REPRO, self.hooks, self.root)

    def test_selected_engine_refuses_a_changed_actual_contract(self):
        replacement = self.token[:-1] + ("0" if self.token[-1] != "0" else "1")
        self.managed.write_text(self.original.replace(self.token, replacement))
        with self.assertRaises(subprocess.CalledProcessError):
            installer.require_generated_contract(REPRO, self.hooks, self.root)

    def test_duplicate_contract_is_refused(self):
        self.managed.write_text(self.original + "\n--hook-contract=" + self.token + "\n")
        with self.assertRaisesRegex(RuntimeError, "ambiguous or invalid"):
            installer.require_generated_contract(REPRO, self.hooks, self.root)

    def test_missing_contract_is_refused(self):
        self.managed.write_text(self.original.replace("--hook-contract=" + self.token, ""))
        with self.assertRaisesRegex(RuntimeError, "ambiguous or invalid"):
            installer.require_generated_contract(REPRO, self.hooks, self.root)

    def test_symlink_managed_hook_is_refused(self):
        retained = self.managed.with_suffix(".retained")
        self.managed.rename(retained)
        self.managed.symlink_to(retained.name)
        with self.assertRaisesRegex(RuntimeError, "regular managed"):
            installer.require_generated_contract(REPRO, self.hooks, self.root)


if __name__ == "__main__":
    unittest.main(argv=[__file__, *remaining])
