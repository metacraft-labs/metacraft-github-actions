"""Fresh real assembler processes through the pinned injector; no mocks."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    driver, assembler, shim, root = sys.argv[1:]
    root = Path(root).resolve()
    outcomes = []

    def run(mode, index):
        folder = root / f"{mode}-{index}"
        folder.mkdir()
        started = time.monotonic()
        with (folder / "parent.log").open("wb") as log:
            process = subprocess.Popen(
                [driver, mode, assembler, shim, str(folder)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=1900)
            except subprocess.TimeoutExpired:
                # Longer than all three production 600-second stages combined.
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=log, stderr=subprocess.STDOUT, check=False)
                code = 124
        return {"mode": mode, "index": index, "exitCode": code,
                "elapsedSeconds": time.monotonic() - started}

    for mode in ("native", "monitored"):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(run, mode, i) for i in range(128)]
            for future in concurrent.futures.as_completed(futures):
                if future.cancelled():
                    continue
                result = future.result()
                outcomes.append(result)
                (root / "results.json").write_text(json.dumps(outcomes, indent=2))
                print(json.dumps(result), flush=True)
                if result["exitCode"]:
                    for pending in futures:
                        pending.cancel()
        if any(item["exitCode"] for item in outcomes):
            return 1
    (root / "completed.json").write_text(json.dumps({"executions": len(outcomes)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
