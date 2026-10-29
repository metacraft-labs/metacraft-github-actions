"""Exercise real file hashing and inherited-control observation.

SDK image files are fixture bytes: this test verifies observation/routing, not
execution, daemon identity, Windows loader behavior or a release qualification.
The lookup-only repro fixture is never executed. All hashes and filesystem
operations use the real Bash/coreutils boundary.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class WindowsSdkReceipt(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sdk receipt ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.payload = b'observed SDK fixture bytes\n'
        for name in ['repro', 'reprobuild.exe', 'runquota.exe', 'runquotad.exe']:
            path = self.bin / name
            path.write_bytes(self.payload)
            path.chmod(0o755)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(('WINDOWS_DIY_SKIP_', 'WINDOWS_DIY_ENSURE_'))
        }
        self.environment.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                                MCL_REPRO_BIN_DIR=str(self.bin),
                                MCL_REPRO_INSTALL_SOURCE='release')

    def run_receipt(self):
        return subprocess.run([shutil.which('bash'), str(HERE / 'record-windows-sdk.sh')],
                              env=self.environment, text=True, capture_output=True,
                              timeout=10)

    def test_actual_images_have_real_hashes_and_absent_sources_stay_missing(self):
        result = self.run_receipt()
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = hashlib.sha256(self.payload).hexdigest()
        for role in ['public-cli', 'installed-engine', 'installed-runquota-cli',
                      'installed-runquota-daemon']:
            self.assertIn(f'role={role} sha256={digest}', result.stdout)
        self.assertIn('role=shipped-repro-config state=missing', result.stdout)
        self.assertIn('inherited-bootstrap-controls=none', result.stdout)

    def test_set_empty_controls_are_recorded_without_other_environment(self):
        self.environment.update(WINDOWS_DIY_SKIP_NARGO='1', WINDOWS_DIY_ENSURE_ONLY='',
                                UNRELATED_JOB_TOKEN='receipt-secret-must-not-appear')
        result = self.run_receipt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('name=WINDOWS_DIY_SKIP_NARGO value=1', result.stdout)
        self.assertIn("name=WINDOWS_DIY_ENSURE_ONLY value=''", result.stdout)
        self.assertNotIn('receipt-secret', result.stdout + result.stderr)
        self.assertNotIn('UNRELATED_JOB_TOKEN', result.stdout + result.stderr)
        self.assertNotIn('inherited-bootstrap-controls=none', result.stdout)

    def test_stale_path_cannot_be_attributed_to_selected_sdk(self):
        other = self.root / 'other SDK'
        other.mkdir()
        self.environment['MCL_REPRO_BIN_DIR'] = str(other)
        result = self.run_receipt()
        self.assertEqual(result.returncode, 1)
        self.assertIn('differs from repro on PATH', result.stderr)

    def test_explicit_daemon_override_is_distinct_from_installed_image(self):
        other = self.root / 'other daemon.exe'
        other.write_bytes(b'distinct override\n')
        self.environment['RUNQUOTAD_BIN'] = str(other)
        result = self.run_receipt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('role=explicit-runquotad-override sha256=' +
                      hashlib.sha256(other.read_bytes()).hexdigest(), result.stdout)
        self.assertNotIn('selected-daemon', result.stdout)

    def test_empty_daemon_override_is_not_reported_unset(self):
        self.environment['RUNQUOTAD_BIN'] = ''
        result = self.run_receipt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RUNQUOTAD_BIN=set-empty', result.stdout)
        self.assertNotIn('RUNQUOTAD_BIN=unset', result.stdout)
        self.assertNotIn('role=explicit-runquotad-override', result.stdout)


if __name__ == '__main__':
    unittest.main()
