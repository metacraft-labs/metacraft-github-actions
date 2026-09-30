"""Time real compiler children and require their COFF output and capture.

No mocks or production deadline changes. The existing driver checks the actual
child PID's start/read/write records for direct and propagated injection.
Alternate the build modes to avoid assigning every later sample to one mode.
This small probe measures startup cost; the full RunQuota graph is separate.
"""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time

driver, assembler, root_arg = sys.argv[1:]
root = Path(root_arg).resolve()
shims = {mode: root / mode / "librepro_monitor_shim.dll"
         for mode in ("debug", "release")}
hashes = {mode: hashlib.sha256(path.read_bytes()).hexdigest()
          for mode, path in shims.items()}
if hashes["debug"] == hashes["release"]:
    raise RuntimeError("Build-mode shims are identical")
(root / "shim-hashes.json").write_text(json.dumps(hashes, indent=2))
results = []
for index in range(16):
    variants = ("debug", "release") if index % 2 == 0 else ("release", "debug")
    cases = [("native", "debug")]
    cases += [(kind, mode) for kind in ("monitored", "propagated") for mode in variants]
    for kind, mode in cases:
        folder = root / f"{kind}-{mode}-{index}"
        folder.mkdir()
        start = time.monotonic()
        expired = False
        with (folder / "parent.log").open("wb") as output:
            child = subprocess.Popen([driver, kind, assembler, str(shims[mode]), str(folder)],
                                     stdin=subprocess.DEVNULL, stdout=output,
                                     stderr=subprocess.STDOUT)
            try:
                code = child.wait(timeout=1900)
            except subprocess.TimeoutExpired:
                expired = True
                if child.poll() is None:
                    subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=30)
                code = child.wait(timeout=30)
        result = dict(kind=kind, mode=mode, index=index, exitCode=code,
                      expired=expired, elapsedSeconds=time.monotonic()-start)
        results.append(result)
        (root / "results.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        if code or expired:
            raise SystemExit(1)
summary = {}
for kind, mode in sorted({(r["kind"], r["mode"]) for r in results}):
    values = [r["elapsedSeconds"] for r in results if (r["kind"], r["mode"]) == (kind, mode)]
    summary[kind + "-" + mode] = dict(samples=len(values), median=statistics.median(values),
                                     maximum=max(values), minimum=min(values))
(root / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary), flush=True)
