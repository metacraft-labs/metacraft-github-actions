"""Repeat the unchanged thread/injection corpus with real child exit controls."""
import hashlib
import json
from pathlib import Path
import subprocess
import time


def main():
    evidence = Path("build/injection-stress").resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    fixture = Path("tests/test_propagation_windows_fork_bomb.nim")
    driver = evidence / "driver.exe"
    target = evidence / "test.exe"
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()
    pins = {}
    for repo in (".", "reprobuild", "io-mon", "nim-stackable-hooks"):
        pins[repo] = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "HEAD"], text=True
        ).strip()
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    for name, source, binary in [
        ("fixture", fixture, target),
        ("driver", Path(__file__).with_name("windows_injection_stress_driver.nim"), driver),
    ]:
        with (evidence / (name + ".build.log")).open("wb") as output:
            subprocess.run(
                ["nim", "c", "--threads:on", "--cpu:amd64", "--cc:gcc",
                 "--path:src", "--nimcache:build/injection-stress-cache/" + name,
                 "--out:" + str(binary), str(source)],
                stdout=output, stderr=subprocess.STDOUT, check=True,
            )

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (fixture, target, driver, shim)}

    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    results = []
    for round_number in range(13):
        for mode in ("native", "monitored"):
            if hashes() != initial:
                raise RuntimeError("An input changed")
            folder = evidence / (mode + "-" + str(round_number))
            folder.mkdir()
            control = round_number == 0
            command = [str(driver), mode, str(driver if control else target),
                       str(shim), str(folder)]
            if control:
                command.append("--exit-code-control")
            start = time.monotonic()
            expired = False
            with (folder / "parent.log").open("wb") as output:
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT)
                try:
                    code = child.wait(timeout=1500)
                except subprocess.TimeoutExpired:
                    expired = True
                    subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=30)
                    code = child.wait(timeout=30)
            record_path = folder / "root-result.json"
            record = json.loads(record_path.read_text()) if record_path.exists() else {}
            log = folder / "target.log"
            text = log.read_text(errors="replace") if log.exists() else ""
            expected = (code == 1 and record.get("rawExitCode") == 0xC0000005
                        if control else code == 0 and record.get("rawExitCode") == 0
                        and text.count("[OK]") == 2)
            result = dict(mode=mode, round=round_number, control=control,
                          driverExitCode=code, expected=expected, outerExpired=expired,
                          elapsedSeconds=time.monotonic() - start, rootResult=record)
            results.append(result)
            print(json.dumps(result), flush=True)
            (evidence / "results.json").write_text(json.dumps(results, indent=2))
            if control and not expected:
                raise RuntimeError("The real DWORD exit-code control failed")
    if hashes() != initial:
        raise RuntimeError("An input changed during execution")
    return int(any(not r["expected"] or r["outerExpired"] for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
