"""Preserve the legacy entrypoint using the caller's declared Node runtime."""

import os
from pathlib import Path

runtime = os.environ.get("GHA_NIX_AUTH_NODE", "")
if not Path(runtime).is_absolute() or not os.access(runtime, os.X_OK):
    raise SystemExit("The declared Actions/owner Node runtime binding is required")
os.execv(runtime, [runtime, str(Path(__file__).with_name("nix-auth.cjs"))])
