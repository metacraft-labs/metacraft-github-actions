"""Compare real ordinary and controlled process exits, preserving evidence.

Only the intentionally stalled owned child is reaped at the diagnostic bound.
The phase observer never suspends target threads. No product timeout changes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

folder, variant = Path(sys.argv[1]).resolve(), sys.argv[2]
base = folder.parent
observer = base / "observer.exe"
results = []
for mode, repeat in (("ordinary", 0), ("scheduled", 1), ("scheduled", 2)):
    case = folder / f"{mode}-{repeat}"
    fragments = case / "fragments"
    fragments.mkdir(parents=True)
    marker = case / "shutdown-probe.txt"
    marker.write_bytes(b"shutdown probe\n")
    env = dict(os.environ, REPRO_MONITOR_FRAGMENT_DIR=str(fragments))
    started = time.monotonic()
    timed_out = False
    samples = []
    with (case / "child.log").open("wb") as output:
        child = subprocess.Popen([str(base / "child.exe"),
                                  str(folder / "librepro_monitor_shim.dll"),
                                  mode, str(marker)], stdout=output,
                                 stderr=subprocess.STDOUT, env=env)
        try:
            birth = subprocess.run([str(observer), "--creation", str(child.pid)],
                                   capture_output=True, text=True, timeout=10)
            if child.poll() is None and (birth.returncode or not birth.stdout.strip().isdigit()):
                raise RuntimeError("Cannot establish controlled child identity")
            for delay in (1, 3, 10, 18):
                while child.poll() is None and time.monotonic() - started < delay:
                    time.sleep(0.05)
                if child.poll() is not None:
                    break
                sample = subprocess.run([str(observer), "--tree", str(child.pid), birth.stdout.strip()],
                                        capture_output=True, text=True, timeout=10)
                samples.append(sample.stdout + sample.stderr)
                (case / "phases.log").write_text("\n".join(samples))
            try:
                child.wait(timeout=max(0.1, 20 - (time.monotonic() - started)))
            except subprocess.TimeoutExpired:
                timed_out = True
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
    log = (case / "child.log").read_text(errors="replace")
    saw_late_flush = any("last_repro_diagnostic_exit_phase=211" in s for s in samples)
    expected_stall = variant == "original" and mode == "scheduled"
    passed = ("SHUTDOWN-CONTROL application complete" in log and
              (timed_out and saw_late_flush if expected_stall else
               not timed_out and child.returncode == 17))
    capture = subprocess.run([str(base / "capture.exe"), str(fragments)],
                             capture_output=True, text=True, timeout=20)
    (case / "capture.log").write_text(capture.stdout + capture.stderr)
    passed = passed and capture.returncode == 0
    result = dict(variant=variant, mode=mode, repeat=repeat, passed=passed,
                  exitCode=child.returncode, timedOut=timed_out,
                  sawLateFlush=saw_late_flush, captureExit=capture.returncode,
                  elapsed=time.monotonic()-started)
    results.append(result)
    print(json.dumps(result), flush=True)
    (folder / "results.json").write_text(json.dumps(results, indent=2))
raise SystemExit(int(any(not r["passed"] for r in results)))
