"""Observe real SQLite worker progress with unchanged concurrency/deadlines.

No mocks: both binaries use the production capture helper and SQLite. Only
the observed fixture adds files recording when each real call completes.
"""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


SOURCE = "libs/runquota_observation_store/tests/t_sqlite_cli_concurrent_spawn.nim"
REVISION = "15e4debcbeae1701d14bfd437149a3850c94875d"


def instrument(text):
    replacements = {
        "import std/[atomics, os, osproc, strutils, tempfiles, unittest]":
        "import std/[atomics, monotimes, os, osproc, strutils, tempfiles, unittest]",
        "    dbPath: string\n":
        "    dbPath: string\n    progressRoot: string\n    workerIndex: int\n",
        "    plan.completed.atomicInc()\n":
        """    plan.completed.atomicInc()
    writeFile(plan.progressRoot / ("worker-" & $plan.workerIndex & "-" &
      $plan.completed.load()), $getMonoTime().ticks)
""",
        "    plans[index].iterations = IterationsPerThread\n":
        """    plans[index].iterations = IterationsPerThread
    plans[index].progressRoot = getEnv("RUNQUOTA_SQLITE_PROGRESS_DIR")
    plans[index].workerIndex = index
    writeFile(plans[index].progressRoot / ("worker-" & $index & "-0"),
      $getMonoTime().ticks)
""",
    }
    for before, after in replacements.items():
        if text.count(before) != 1:
            raise RuntimeError("The real worker observation anchor changed")
        text = text.replace(before, after)
    return text


def main():
    evidence = Path("build/sqlite-progress").resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    pins = {name: subprocess.check_output(
        ["git", "-C", name, "rev-parse", "HEAD"], text=True).strip()
        for name in (".", "reprobuild", "io-mon", "nim-stackable-hooks")}
    if pins["."] != REVISION:
        raise RuntimeError("Unexpected RunQuota source")
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    source = Path(SOURCE)
    original_bytes = source.read_bytes()
    original = source.read_text()
    if subprocess.check_output(["git", "diff", "HEAD", "--", SOURCE]):
        raise RuntimeError("The baseline fixture is modified")
    binaries = {}
    try:
        for variant, text in {"original": original, "observed": instrument(original)}.items():
            (evidence / (variant + ".nim")).write_text(text)
            # Keep the fixture at its real path so relative support imports
            # and its normal parent configuration remain unchanged.
            source.write_text(text)
            binary = evidence / (variant + ".exe")
            binaries[variant] = binary
            with (evidence / (variant + ".build.log")).open("wb") as output:
                subprocess.run(["nim", "c", "--threads:on", "--cpu:amd64",
                                "--nimcache:build/sqlite-progress-cache/" + variant,
                                "--out:" + str(binary), SOURCE],
                               stdout=output, stderr=subprocess.STDOUT, check=True)
    finally:
        source.write_bytes(original_bytes)

    repro, bash, sqlite = (shutil.which(name) for name in ("repro", "bash", "sqlite3"))
    if not all((repro, bash, sqlite)):
        raise RuntimeError("Missing activated runtime tools")
    if "GNU bash" not in subprocess.check_output([bash, "--version"], text=True):
        raise RuntimeError("Unexpected Bash launcher")
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [*binaries.values(), shim, Path(sqlite)]}

    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    outcomes = []
    phases = [("native-original", "native", "original", 1),
              ("native-observed", "native", "observed", 1),
              ("monitored-original", "monitored", "original", 1),
              ("monitored-first", "monitored", "observed", 1),
              ("monitored-parallel", "monitored", "observed", 8),
              ("monitored-last", "monitored", "observed", 1)]
    for phase, mode, variant, copies in phases:
        if hashes() != initial:
            raise RuntimeError("A comparison input changed")

        def run(index):
            folder = evidence / (phase + "-" + str(index))
            folder.mkdir()
            progress = folder / "progress"
            progress.mkdir()
            env = os.environ.copy()
            env["RUNQUOTA_SQLITE_PROGRESS_DIR"] = str(progress)
            command = [bash, "-c", 'timeout --kill-after=10 600 "$1" </dev/null',
                       "sqlite-progress", str(binaries[variant]).replace("\\", "/")]
            if mode == "monitored":
                env["REPRO_MONITOR_SHIM_LIB"] = str(shim)
                command = [repro, "internal", "io", "monitor", "--depfile",
                           str(folder / "monitor.iomon"), "--", *command]
            started = time.monotonic()
            expired = False
            with (folder / "target.log").open("wb") as output:
                child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT)
                try:
                    code = child.wait(timeout=1200)
                except subprocess.TimeoutExpired:
                    expired = True
                    subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=30)
                    code = child.wait(timeout=30)
            records = {}
            for path in progress.glob("worker-*"):
                parts = path.name.split("-")
                row = {"completed": int(parts[2]), "ticks": None}
                try:
                    row["ticks"] = int(path.read_text())
                except (OSError, ValueError) as error:
                    # A killed worker may have created its last marker but
                    # not finished writing it. Preserve that fact as evidence.
                    row["readError"] = str(error)
                records.setdefault(parts[1], []).append(row)
            for rows in records.values():
                rows.sort(key=lambda row: row["completed"])
            (folder / "progress.json").write_text(json.dumps(records, indent=2))
            output_text = (folder / "target.log").read_text(errors="replace")
            return dict(phase=phase, mode=mode, variant=variant, index=index,
                        exitCode=code, outerExpired=expired,
                        elapsedSeconds=time.monotonic() - started,
                        passedAssertions=output_text.count("[OK]"),
                        completed={k: max(r["completed"] for r in rows)
                                   for k, rows in records.items()})

        with concurrent.futures.ThreadPoolExecutor(max_workers=copies) as pool:
            futures = [pool.submit(run, index) for index in range(copies)]
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                outcomes.append(result)
                print(json.dumps(result), flush=True)
                (evidence / "results.json").write_text(json.dumps(outcomes, indent=2))
    if hashes() != initial:
        raise RuntimeError("A comparison input changed during execution")
    return int(any(r["exitCode"] or r["outerExpired"] or r["passedAssertions"] != 1
                   for r in outcomes))


if __name__ == "__main__":
    raise SystemExit(main())
