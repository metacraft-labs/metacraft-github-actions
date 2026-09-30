"""Compare real ordinary and controlled process exits, preserving evidence.

Only the intentionally stalled owned child is reaped at the diagnostic bound.
The phase observer never suspends target threads. No product timeout changes.
"""
import json
import os
import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import time
import uuid

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.CreateEventW.argtypes = (ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR)
kernel.CreateEventW.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
kernel.WaitForSingleObject.restype = wintypes.DWORD
kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
kernel.CloseHandle.restype = wintypes.BOOL

folder, variant = Path(sys.argv[1]).resolve(), sys.argv[2]
base = folder.parent
observer = base / "windows-process-phase.exe"
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
    # The parent retains this real event after child exit. A successful exit
    # cannot masquerade as a repair if the scheduled lock owner never ran.
    held_name = "Local\\io-mon-shutdown-held-" + uuid.uuid4().hex
    held_event = kernel.CreateEventW(None, True, False, held_name)
    if not held_event:
        raise ctypes.WinError(ctypes.get_last_error())
    with (case / "child.log").open("wb") as output:
        child = subprocess.Popen([str(base / "child.exe"),
                                  str(folder / "librepro_monitor_shim.dll"),
                                  mode, str(marker), held_name], stdout=output,
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
    held_observed = kernel.WaitForSingleObject(held_event, 0) == 0
    kernel.CloseHandle(held_event)
    saw_late_flush = any("last_repro_diagnostic_exit_phase=211" in s for s in samples)
    expected_stall = variant == "original" and mode == "scheduled"
    passed = ("SHUTDOWN-CONTROL application complete" in log and
              (held_observed if mode == "scheduled" else not held_observed) and
              (timed_out and saw_late_flush if expected_stall else
               not timed_out and child.returncode == 17))
    capture = subprocess.run([str(base / "capture.exe"), str(fragments)],
                             capture_output=True, text=True, timeout=20)
    (case / "capture.log").write_text(capture.stdout + capture.stderr)
    passed = passed and capture.returncode == 0
    result = dict(variant=variant, mode=mode, repeat=repeat, passed=passed,
                  exitCode=child.returncode, timedOut=timed_out,
                  heldObserved=held_observed,
                  sawLateFlush=saw_late_flush, captureExit=capture.returncode,
                  elapsed=time.monotonic()-started)
    results.append(result)
    print(json.dumps(result), flush=True)
    (folder / "results.json").write_text(json.dumps(results, indent=2))
raise SystemExit(int(any(not r["passed"] for r in results)))
