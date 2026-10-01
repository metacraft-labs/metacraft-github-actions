"""Compare real observation fixtures with delayed real SQLite writes.

No mocks: the proxy forwards unchanged SQL to the activated SQLite and
preserves its actual output and exit status. Only write timing changes.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

BASELINE = "b4a9c53a80f3ba2f1524db0eb0614b40aecef1fc"
REVISION = "2d3897c89f1a74c9fd8d7b9e3143d2eecda3b833"
SOURCES = {
    "socket": "tests/integration/t_observation_socket_write_path.nim",
    "stats": "tests/integration/t_stats_table_publication.nim",
}
CASE = "a store that turns unwritable mid-flight degrades and never fails a client"


def main():
    evidence = Path("build/observation-barriers").resolve()
    evidence.mkdir(parents=True)
    pins = {name: subprocess.check_output(
        ["git", "-C", name, "rev-parse", "HEAD"], text=True).strip()
        for name in (".", "reprobuild", "io-mon", "nim-stackable-hooks")}
    changed = subprocess.check_output(
        ["git", "diff", "--name-only", BASELINE, "HEAD"], text=True).splitlines()
    if pins["."] != REVISION or sorted(changed) != sorted(SOURCES.values()):
        raise RuntimeError("Unexpected fixture comparison sources")
    if subprocess.check_output(["git", "diff", "HEAD", "--", *SOURCES.values()]):
        raise RuntimeError("Modified comparison sources")
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    (evidence / "source-change.patch").write_bytes(
        subprocess.check_output(["git", "diff", BASELINE, "HEAD"]))
    bash, repro, sqlite = (shutil.which(n) for n in ("bash", "repro", "sqlite3"))
    if not all((bash, repro, sqlite)):
        raise RuntimeError("Missing activated tools")
    if "GNU bash" not in subprocess.check_output([bash, "--version"], text=True):
        raise RuntimeError("Unexpected Bash launcher")
    with (evidence / "apps.build.log").open("wb") as output:
        subprocess.run([bash, "scripts/build_apps.sh"], stdout=output,
                       stderr=subprocess.STDOUT, check=True)

    def compile_source(name, source, binary):
        with (evidence / (name + ".build.log")).open("wb") as output:
            subprocess.run(["nim", "c", "--threads:on", "--cpu:amd64",
                            "--nimcache:build/observation-barrier-cache/" + name,
                            "--out:" + str(binary), str(source)], stdout=output,
                           stderr=subprocess.STDOUT, check=True)

    binaries = {}
    for name, filename in SOURCES.items():
        source = Path(filename)
        fixed = source.read_bytes()
        try:
            for variant in ("original", "fixed"):
                content = fixed if variant == "fixed" else subprocess.check_output(
                    ["git", "show", BASELINE + ":" + filename])
                source.write_bytes(content)
                key = name + "-" + variant
                (evidence / (key + ".nim")).write_bytes(content)
                binary = evidence / (key + ".exe")
                compile_source(key, source, binary)
                binaries[key] = binary
        finally:
            source.write_bytes(fixed)
    proxy_dir = evidence / "proxy"
    proxy_dir.mkdir()
    proxy = proxy_dir / "sqlite3.exe"
    compile_source("proxy", Path(__file__).with_name("runquota_sqlite_delay_proxy.nim"), proxy)
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()
    inputs = [*binaries.values(), *Path("build/bin").glob("*.exe"), proxy, shim, Path(sqlite)]

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    cases = [("original", "socket-original", 0, CASE, 0, 1),
             ("original-delay", "socket-original", 6500, CASE, 1, 0),
             ("fixed-delay", "socket-fixed", 6500, CASE, 0, 1),
             ("fixed-full", "socket-fixed", 0, None, 0, 10),
             ("stats-original", "stats-original", 0, None, 0, 4),
             ("stats-fixed", "stats-fixed", 0, None, 0, 4)]
    results = []
    for mode in ("native", "monitored"):
        for name, key, delay, selection, expected_code, passes in cases:
            if hashes() != initial:
                raise RuntimeError("A comparison input changed")
            folder = evidence / (mode + "-" + name)
            folder.mkdir()
            records = folder / "delayed-writes"
            records.mkdir()
            env = os.environ.copy()
            env["PATH"] = str(proxy_dir) + os.pathsep + env["PATH"]
            env["RUNQUOTA_REAL_SQLITE"] = sqlite
            env["RUNQUOTA_SQLITE_DELAY_MS"] = str(delay)
            env["RUNQUOTA_SQLITE_DELAY_RECORDS"] = str(records)
            command = [bash, "-c", 'timeout --kill-after=10 600 "$@" </dev/null',
                       "observation-barriers", str(binaries[key]).replace("\\", "/")]
            if selection:
                command.append(selection)
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
            text = (folder / "target.log").read_text(errors="replace")
            delayed = len(list(records.glob("*.sql")))
            expected = code == expected_code and text.count("[OK]") == passes
            if delay:
                expected = expected and delayed > 0
            if expected_code:
                expected = expected and text.count("[FAILED]") == 1 and "Check failed: degraded[" in text
            row = dict(mode=mode, name=name, exitCode=code, expected=expected,
                       outerExpired=expired, delayedCalls=delayed,
                       passingCases=text.count("[OK]"), failingCases=text.count("[FAILED]"),
                       seconds=time.monotonic() - started)
            results.append(row)
            print(json.dumps(row), flush=True)
            (evidence / "results.json").write_text(json.dumps(results, indent=2))
    if hashes() != initial:
        raise RuntimeError("A comparison input changed during execution")
    return int(any(not r["expected"] or r["outerExpired"] for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
