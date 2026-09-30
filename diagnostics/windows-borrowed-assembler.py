"""Fresh real assembler processes through the pinned injector; no mocks."""
import concurrent.futures
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("driver", "assembler", "shim", "root"):
        parser.add_argument(name)
    parser.add_argument("--samples", type=int, default=128)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    if args.workers < 1:
        parser.error("--workers must be positive")
    driver, assembler, shim = args.driver, args.assembler, args.shim
    root = Path(args.root).resolve()
    (root / "settings.json").write_text(json.dumps({
        "nativeSamples": 128, "monitoredSamplesPerMode": args.samples,
        "concurrentParents": args.workers}, indent=2))
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

    for mode in ("native", "monitored", "propagated"):
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            count = 128 if mode == "native" else args.samples
            futures = [executor.submit(run, mode, i) for i in range(count)]
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
