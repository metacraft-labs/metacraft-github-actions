#!/usr/bin/env python3
"""Contract tests for tools/check-pins.py (local mode only, no network).

No mocks: each case writes real pin files into a temporary directory next to
the real schema and runs the real script as a subprocess. The remote checks
need a private repository and a token, and are exercised by the `pins`
workflow itself.
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOOD = {
    "schema": 1, "tool": "demo", "owner": "some-owner", "repo": "some-repo",
    "rev": "0123456789abcdef0123456789abcdef01234567",
    "narHash": "sha256-" + "A" * 43 + "=",
}


class CheckPins(unittest.TestCase):
    def run_with(self, **files):
        with tempfile.TemporaryDirectory() as tmp:
            pins = pathlib.Path(tmp)
            shutil.copy(ROOT / "pins" / "pin.schema.json", pins)
            for name, body in files.items():
                (pins / f"{name}.json").write_text(
                    body if isinstance(body, str) else json.dumps(body))
            done = subprocess.run(
                [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py"),
                 "--pins-dir", str(pins)], capture_output=True, text=True)
            return done.returncode, done.stdout + done.stderr

    def test_the_real_pins_pass(self):
        done = subprocess.run(
            [sys.executable, "-I", str(ROOT / "tools" / "check-pins.py")],
            capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_good_pin_passes(self):
        code, out = self.run_with(demo=GOOD)
        self.assertEqual(code, 0, out)

    def test_attrs_and_flake_are_accepted(self):
        code, out = self.run_with(demo={**GOOD, "flake": False, "attrs": {"a": "b"}})
        self.assertEqual(code, 0, out)

    def test_systems_must_be_known_and_nonempty(self):
        for systems in ([], ["vax"], "x86_64-linux"):
            code, _ = self.run_with(demo={**GOOD, "systems": systems})
            self.assertEqual(code, 1, systems)
        code, out = self.run_with(demo={**GOOD, "systems": ["x86_64-linux"]})
        self.assertEqual(code, 0, out)

    def test_tool_must_equal_the_file_name(self):
        code, out = self.run_with(other=GOOD)
        self.assertEqual(code, 1)
        self.assertIn("must equal the file name", out)

    def test_unknown_field_is_rejected(self):
        code, out = self.run_with(demo={**GOOD, "revv": "x"})
        self.assertEqual(code, 1)
        self.assertIn("unknown field 'revv'", out)

    def test_missing_required_field_is_rejected(self):
        bad = {k: v for k, v in GOOD.items() if k != "narHash"}
        code, out = self.run_with(demo=bad)
        self.assertEqual(code, 1)
        self.assertIn("missing required field 'narHash'", out)

    def test_a_branch_is_not_a_rev(self):
        code, out = self.run_with(demo={**GOOD, "rev": "agents"})
        self.assertEqual(code, 1)
        self.assertIn("rev", out)

    def test_a_short_or_uppercase_rev_is_rejected(self):
        for rev in (GOOD["rev"][:39], GOOD["rev"].upper()):
            code, _ = self.run_with(demo={**GOOD, "rev": rev})
            self.assertEqual(code, 1, rev)

    def test_a_non_sri_hash_is_rejected(self):
        code, _ = self.run_with(demo={**GOOD, "narHash": "sha1-" + "A" * 27})
        self.assertEqual(code, 1)

    def test_wrong_schema_version_is_rejected(self):
        code, _ = self.run_with(demo={**GOOD, "schema": 2})
        self.assertEqual(code, 1)

    def test_a_boolean_is_not_the_schema_integer(self):
        code, _ = self.run_with(demo={**GOOD, "schema": True})
        self.assertEqual(code, 1)

    def test_attrs_values_must_be_nonempty_strings(self):
        for attrs in ({"a": ""}, {"a": 3}):
            code, _ = self.run_with(demo={**GOOD, "attrs": attrs})
            self.assertEqual(code, 1, attrs)

    def test_invalid_json_is_a_failure_not_a_crash(self):
        code, out = self.run_with(demo="{not json")
        self.assertEqual(code, 1)
        self.assertIn("cannot be read as JSON", out)

    def test_an_empty_directory_is_a_usage_error(self):
        code, _ = self.run_with()
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
