"""Observe real fixed test binaries without suspending their process trees.

No mocks. Native and monitored invocations keep the production GNU timeout,
stdin and assertions. Separate read-only observers preserve phase/CPU evidence.
"""
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

NAMES = ("t_observation_store_export", "t_observation_store_merge",
         "t_observation_retention_schedule")


def main():
    evidence = Path("build/windows-runtime-phases").resolve()
    observer = evidence / "windows-process-phase.exe"
    binaries = {name: Path("build/test-bin", name + ".exe").resolve() for name in NAMES}
    images = list(binaries.values()) + list(Path("build/bin").glob("*.exe"))

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in images}

    baseline = hashes()
    (evidence / "binary-sha256.json").write_text(json.dumps(baseline, indent=2))
    repro, bash = shutil.which("repro"), shutil.which("bash")
    if not repro or not bash:
        raise RuntimeError("Missing activated compiler environment")
    outcomes = []
    for mode in ("native", "monitored"):
        if hashes() != baseline:
            raise RuntimeError("A comparison binary changed")
        folder = evidence / mode
        folder.mkdir(exist_ok=True)

        def run(name):
            command = [bash, "-c", 'timeout --kill-after=10 600 "$1" </dev/null',
                       "runquota-runtime-phases", str(binaries[name]).replace("\\", "/")]
            if mode == "monitored":
                command = [repro, "internal", "io", "monitor", "--depfile",
                           str(folder / (name + ".iomon")), "--", *command]
            started = time.monotonic()
            started_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
            samples = iter((3, 20, 120, 300, 570, 620, 1250))
            next_sample = next(samples)
            outer_expired = False
            with (folder / (name + ".log")).open("wb") as output, \
                    (folder / (name + ".phases.log")).open("wb") as phases:
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT)
                try:
                    created = subprocess.run([str(observer), "--creation", str(child.pid)],
                                             capture_output=True, text=True, timeout=30)
                    expected = created.stdout.strip()
                    if child.poll() is None and (created.returncode or not expected.isdigit() or expected == "0"):
                        raise RuntimeError("Cannot establish the observed root identity")
                    while child.poll() is None:
                        elapsed = time.monotonic() - started
                        if elapsed >= next_sample:
                            phases.write(f"SAMPLE elapsed={elapsed:.3f} root={child.pid}\n".encode())
                            phases.flush()
                            try:
                                probe = subprocess.run([str(observer), "--tree", str(child.pid), expected],
                                                       stdout=phases, stderr=subprocess.STDOUT, timeout=30)
                                phases.write(f"SAMPLE observer-exit={probe.returncode}\n".encode())
                            except subprocess.TimeoutExpired:
                                # Killing an observer cannot leave a target suspended:
                                # its observation path never suspends a target thread.
                                phases.write(b"SAMPLE observer-timeout\n")
                            phases.flush()
                            next_sample = next(samples, float("inf"))
                        if elapsed > 1900:
                            # Outer diagnostic bound covers the existing injection
                            # stages plus GNU timeout. Own this one process subtree.
                            outer_expired = True
                            if child.poll() is None:
                                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                               stdout=phases, stderr=subprocess.STDOUT, timeout=30)
                            break
                        time.sleep(1)
                    code = child.wait(timeout=30)
                finally:
                    if child.poll() is None:
                        subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                       stdout=phases, stderr=subprocess.STDOUT, timeout=30)
                        child.wait(timeout=30)
            return {"mode": mode, "name": name, "exitCode": code, "outerExpired": outer_expired,
                    "rootPid": child.pid, "rootCreation": expected, "startedUtc": started_utc,
                    "elapsedSeconds": time.monotonic() - started}

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(run, name) for name in NAMES]
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                outcomes.append(result)
                print(json.dumps(result), flush=True)
                (evidence / "results.json").write_text(json.dumps(outcomes, indent=2))
        if hashes() != baseline:
            raise RuntimeError("A comparison binary changed during execution")
    return int(any(r["exitCode"] or r["outerExpired"] for r in outcomes))


if __name__ == "__main__":
    raise SystemExit(main())
