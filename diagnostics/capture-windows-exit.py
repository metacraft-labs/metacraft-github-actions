"""Keep the full Windows exit status and regular-file output; no shell wrapper."""
import json
from pathlib import Path
import subprocess
import sys
import time

prefix = Path(sys.argv[1])
argv = sys.argv[2:]
started = time.monotonic()
timed_out = False
with Path(str(prefix) + '.log').open('wb') as output:
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output,
                             stderr=subprocess.STDOUT)
    try:
        code = child.wait(timeout=180)
    except subprocess.TimeoutExpired:
        timed_out = True
        subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                       stdout=output, stderr=subprocess.STDOUT, check=False)
        code = child.wait(timeout=30)
result = {'argv': argv, 'exitCode': code, 'exitHex': hex(code & 0xffffffff),
          'timedOut': timed_out, 'seconds': round(time.monotonic()-started, 3)}
Path(str(prefix) + '.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
