"""Restore directory write access only in one identified stale test fixture.

Job 109314731119 could not clean a copied Nix compiler tree. No files are
deleted, no file contents or source-store modes change, and no process is
stopped. The product fix copies future mutable fixtures without store modes.
"""

import os
from pathlib import Path
import stat


runner = os.environ.get("RUNNER_NAME", "")
# sudo may omit RUNNER_NAME; the immutable absolute path is the repair scope.
if runner and runner not in {f"m3-mcl-{number:03d}" for number in range(1, 7)}:
    raise SystemExit("Refusing repair outside the persistent m3 fleet")

root = Path("/private/var/lib/github-runner-work/mcl-004/runquota/runquota/"
            "build/test-work/runquota-ref-scanner.45Vbdy/hostile-project/scripts/compiler")
if not root.exists():
    print("The recorded fixture is already absent; no change required.")
    raise SystemExit(0)
if root.resolve(strict=True) != root or root.is_symlink():
    raise SystemExit("Refusing a fixture path containing symlinks")

owner = root.stat().st_uid
changed = 0
for current, directories, _ in os.walk(root, followlinks=False):
    directories[:] = [name for name in directories
                      if not (Path(current) / name).is_symlink()]
    descriptor = os.open(current, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        details = os.fstat(descriptor)
        if details.st_uid != owner:
            raise SystemExit("Refusing a directory with a different owner")
        mode = stat.S_IMODE(details.st_mode)
        if mode & 0o700 != 0o700:
            os.fchmod(descriptor, mode | 0o700)
            changed += 1
    finally:
        os.close(descriptor)
print(f"Restored owner access on {changed} directories in {root}")
