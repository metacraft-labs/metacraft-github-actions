"""Keep the real CLI's shared-memory host alive for an external debugger."""
import json
import os
from pathlib import Path
import sys
import time

destination = Path(sys.argv[1])
destination.write_text(json.dumps({key: value for key, value in os.environ.items()
                                  if key.startswith('REPRO_MONITOR_')
                                  or key == 'LD_PRELOAD'}))
deadline = time.monotonic() + 540
while not destination.with_suffix('.stop').exists():
    if time.monotonic() >= deadline:
        raise SystemExit('Debugger did not release its monitor host in time')
    time.sleep(0.1)
