"""Compare real fixed binaries under the production monitor; no mocks.

Only admission of independent test programs varies. Their internal workers,
assertions, stdin, GNU timeout and child monitoring stay intact. This focused
diagnostic supplements the mandatory complete Reprobuild CI graph.
"""

import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time


NAMES = [
    "t_e2e_runquota_concurrent_short_lived_clients",
    "t_m5_process_exec_bench_contract",
    "t_observation_socket_write_path",
    "t_stats_table_cache_control",
    "t_observation_retention_schedule",
    "t_observation_store_export",
    "t_observation_store_merge",
]


def main():
    evidence = Path("build/windows-arm-test-contention").resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    binaries = {name: Path("build/test-bin", name + ".exe").resolve() for name in NAMES}
    images = list(binaries.values()) + list(Path("build/bin").glob("*.exe"))

    def hashes():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in images}

    baseline = hashes()
    (evidence / "binary-sha256.json").write_text(json.dumps(baseline, indent=2))
    repro = shutil.which("repro")
    bash = shutil.which("bash")
    if not repro or not bash:
        raise RuntimeError("The real activated toolchain is missing")
    outcomes = []

    for mode, parallelism in [("parallel-first", 8), ("serial", 1), ("parallel-second", 8)]:
        if hashes() != baseline:
            raise RuntimeError("A comparison binary changed before execution")
        mode_dir = evidence / mode
        mode_dir.mkdir(exist_ok=True)

        def run(name):
            started = time.monotonic()
            started_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
            command = [repro, "internal", "io", "monitor", "--depfile",
                       str(mode_dir / (name + ".iomon")), "--", bash, "-c",
                       'timeout --kill-after=10 600 "$1" </dev/null',
                       "runquota-contention", str(binaries[name]).replace("\\", "/")]
            with (mode_dir / (name + ".log")).open("wb") as log:
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                         stdout=log, stderr=subprocess.STDOUT)
                code = child.wait()
            return {"name": name, "exitCode": code, "pid": child.pid,
                    "startedUtc": started_utc,
                    "finishedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "elapsedSeconds": time.monotonic() - started}

        record = {"mode": mode, "parallelism": parallelism, "programs": []}
        outcomes.append(record)
        with concurrent.futures.ThreadPoolExecutor(max_workers=parallelism) as executor:
            futures = [executor.submit(run, name) for name in NAMES]
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                record["programs"].append(result)
                print(json.dumps({"mode": mode, **result}), flush=True)
                (evidence / "results.json").write_text(json.dumps(outcomes, indent=2))
        if len(record["programs"]) != len(NAMES) or hashes() != baseline:
            raise RuntimeError("Incomplete comparison or changed binary")
    return int(any(program["exitCode"] != 0 for record in outcomes for program in record["programs"]))


if __name__ == "__main__":
    raise SystemExit(main())
