"""Compare real first injection callers with lazy and module-time lock setup.

Both variants use the same start-gated fixture and monitor. No APIs or results
are mocked. An original failure is retained; repaired failures fail the run.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import time


def main():
    evidence = Path("build/injection-lock-pair").resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    source = "src/stackable_hooks/propagation_windows.nim"
    fixture = "tests/test_propagation_windows_fork_bomb.nim"
    original = "4371faeb0ef3f9b8911d3b37b0ffd3a39f44c25b"
    repaired = "43b1835128331fef09ecf64a614dbf46880dbe9f"
    if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != repaired:
        raise RuntimeError("Unexpected helper source")
    versions = {"original": original, "initialized": repaired}
    pins = {name: subprocess.check_output(["git", "-C", name, "rev-parse", "HEAD"],
                                        text=True).strip()
            for name in (".", "reprobuild", "io-mon", "nim-stackable-hooks")}
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    (evidence / "versions.json").write_text(json.dumps(versions, indent=2))
    (evidence / "source-change.patch").write_bytes(
        subprocess.check_output(["git", "diff", original, repaired]))
    driver = evidence / "driver.exe"
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()

    def compile_source(name, path, binary):
        with (evidence / (name + ".build.log")).open("wb") as output:
            subprocess.run(["nim", "c", "--threads:on", "--cpu:amd64", "--cc:gcc",
                            "--path:src", "--nimcache:build/injection-lock-cache/" + name,
                            "--out:" + str(binary), str(path)],
                           stdout=output, stderr=subprocess.STDOUT, check=True)

    compile_source("driver", Path(__file__).with_name("windows_injection_stress_driver.nim"), driver)
    binaries = {}
    try:
        for variant, revision in versions.items():
            subprocess.run(["git", "restore", "--source=" + revision, "--", source], check=True)
            binary = evidence / (variant + ".exe")
            binaries[variant] = binary
            compile_source(variant, fixture, binary)
    finally:
        subprocess.run(["git", "restore", "--source=HEAD", "--", source], check=True)

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [Path(fixture), driver, shim, *binaries.values()]}

    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    results = []
    for variant, binary in binaries.items():
        for mode in ("native", "monitored"):
            for index in range(13):
                if hashes() != initial:
                    raise RuntimeError("An input changed")
                folder = evidence / f"{variant}-{mode}-{index}"
                folder.mkdir()
                control = index == 0
                command = [str(driver), mode, str(driver if control else binary),
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
                path = folder / "root-result.json"
                root = json.loads(path.read_text()) if path.exists() else {}
                log = folder / "target.log"
                text = log.read_text(errors="replace") if log.exists() else ""
                expected = (code == 1 and root.get("rawExitCode") == 0xC0000005
                            if control else code == 0 and root.get("rawExitCode") == 0
                            and text.count("[OK]") == 2)
                result = dict(variant=variant, mode=mode, index=index, control=control,
                              driverExitCode=code, expected=expected, outerExpired=expired,
                              elapsedSeconds=time.monotonic() - start, rootResult=root)
                results.append(result)
                print(json.dumps(result), flush=True)
                (evidence / "results.json").write_text(json.dumps(results, indent=2))
                if control and not expected:
                    raise RuntimeError("The real DWORD exit-code control failed")
                if expired:
                    # Retain a timed-out sample, then exercise the other mode
                    # and candidate instead of repeating a known long wait.
                    break
    if hashes() != initial:
        raise RuntimeError("An input changed during execution")
    return int(any((not r["expected"] or r["outerExpired"])
                   and (r["control"] or r["variant"] == "initialized") for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
