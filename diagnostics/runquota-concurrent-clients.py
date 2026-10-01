"""Retain real concurrent clients' output and initial connection failures.

No mocks: the existing 32-client fixture, daemon, CLI, named pipes and child
commands run unchanged except for diagnostic output. Original samples control
for that instrumentation. A missing-daemon control proves the instrumented
CLI reports its actual fallback while preserving the child's successful exit.
"""
import ctypes
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

REVISION = "d6ee4588f71604376a4cc41ef281d6c479395efc"
FIXTURE = "tests/e2e/concurrent-clients/t_e2e_runquota_concurrent_short_lived_clients.nim"
CLI = "libs/runquota_cli_support/src/runquota_cli_support.nim"
MARKER = "diagnostic initial connection failure: "


def observed_sources(fixture, cli):
    original = "import std/[os, osproc, unittest]"
    assert fixture.count(original) == 1
    observed = fixture.replace(original, "import std/[os, osproc, streams, unittest]")
    original = """        check clients[i].waitForExit(5000) == 0
        clients[i].close()"""
    replacement = """        check clients[i].waitForExit(5000) == 0
        echo "diagnostic client ", i, " output begins"
        var buffer: array[8192, char]
        while true:
          let count = clients[i].outputStream.readData(addr buffer[0], buffer.len)
          if count == 0: break
          discard stdout.writeBuffer(addr buffer[0], count)
        echo "diagnostic client ", i, " output ends"
        clients[i].close()"""
    assert observed.count(original) == 1
    observed = observed.replace(original, replacement)
    original = """  except CatchableError:
    return runStandaloneAcquire(label, statsKey, command)"""
    replacement = """  except CatchableError as error:
    stderr.writeLine("diagnostic initial connection failure: " & error.msg)
    return runStandaloneAcquire(label, statsKey, command)"""
    assert cli.count(original) == 1
    return observed, cli.replace(original, replacement)


def main():
    evidence = Path("build/concurrent-client-evidence").resolve()
    evidence.mkdir(parents=True)
    if os.name != "nt" or ctypes.windll.kernel32.GetCurrentProcessId() != os.getpid():
        raise RuntimeError("This diagnostic requires native Windows Python process IDs")
    pins = {name: subprocess.check_output(
        ["git", "-C", name, "rev-parse", "HEAD"], text=True).strip()
        for name in (".", "reprobuild", "io-mon", "nim-stackable-hooks")}
    if pins["."] != REVISION or subprocess.check_output(["git", "diff", "HEAD"]):
        raise RuntimeError("Unexpected or modified source checkout")
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    (evidence / "python.json").write_text(json.dumps({
        "executable": sys.executable, "pid": os.getpid(), "os": os.name}, indent=2))
    bash, repro, sqlite, true = (shutil.which(n) for n in ("bash", "repro", "sqlite3", "true"))
    if not all((bash, repro, sqlite, true)):
        raise RuntimeError("Missing activated tools")
    with (evidence / "apps.build.log").open("wb") as output:
        subprocess.run([bash, "scripts/build_apps.sh"], stdout=output,
                       stderr=subprocess.STDOUT, check=True)
    original_cli = evidence / "original-cli.exe"
    active_cli = Path("build/bin/runquota.exe").resolve()
    shutil.copy2(active_cli, original_cli)

    def compile_source(name, source, binary, flags=()):
        with (evidence / (name + ".build.log")).open("wb") as output:
            subprocess.run(["nim", "c", "--threads:on", "--cpu:amd64",
                            "--nimcache:build/concurrent-client-cache/" + name,
                            "--out:" + str(binary), *flags, str(source)],
                           stdout=output, stderr=subprocess.STDOUT, check=True)

    originals = [Path(FIXTURE).read_text(), Path(CLI).read_text()]
    observed = observed_sources(*originals)
    fixture_bins = {}
    for variant, content in (("original", originals[0]), ("observed", observed[0])):
        source = evidence / (variant + "_fixture.nim")
        source.write_text(content)
        binary = evidence / (variant + "-fixture.exe")
        compile_source(variant, source, binary)
        fixture_bins[variant] = binary
    overlay = evidence / "observed-library"
    overlay.mkdir()
    (overlay / "runquota_cli_support.nim").write_text(observed[1])
    observed_main = overlay / "observed_cli.nim"
    observed_main.write_bytes(Path("apps/runquota/runquota.nim").read_bytes())
    observed_cli = evidence / "observed-cli.exe"
    compile_source("observed-cli", observed_main, observed_cli)
    if MARKER.encode() not in observed_cli.read_bytes() or MARKER.encode() in original_cli.read_bytes():
        raise RuntimeError("The compiled CLI variants do not match their diagnostic marker")
    for name, original, revised in zip(("fixture", "cli"), originals, observed):
        (evidence / (name + ".patch")).write_text("".join(difflib.unified_diff(
            original.splitlines(True), revised.splitlines(True),
            fromfile="original/" + name, tofile="observed/" + name)))
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()
    inputs = [original_cli, observed_cli, *fixture_bins.values(),
              Path("build/bin/runquotad.exe"), shim, Path(sqlite), Path(true)]
    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    results = []

    def execute(name, command, env, wanted_marker=None):
        if hashes() != initial:
            raise RuntimeError("A diagnostic input changed")
        folder = evidence / name
        folder.mkdir()
        started = time.monotonic()
        expired = False
        with (folder / "target.log").open("wb") as output:
            child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                     stdout=output, stderr=subprocess.STDOUT)
            try:
                code = child.wait(timeout=720)
            except subprocess.TimeoutExpired:
                expired = True
                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                               stdout=output, stderr=subprocess.STDOUT, timeout=30)
                code = child.wait(timeout=30)
        output = (folder / "target.log").read_text(errors="replace")
        markers = [line for line in output.splitlines() if MARKER in line]
        expected = code == 0 and not expired
        if wanted_marker is None:
            expected = expected and output.count("[OK]") == 1
        else:
            expected = expected and bool(markers) == wanted_marker
        row = dict(name=name, exitCode=code, outerExpired=expired,
                   expected=expected, seconds=time.monotonic() - started,
                   passingCases=output.count("[OK]"), connectionFailures=markers,
                   clientOutputs=output.count(" output begins"))
        results.append(row)
        print(json.dumps(row), flush=True)
        (evidence / "results.json").write_text(json.dumps(results, indent=2))

    try:
        for variant, binary in (("original", original_cli), ("observed", observed_cli)):
            env = os.environ.copy()
            env["RUNQUOTA_SOCKET"] = "\\\\.\\pipe\\rq-absent-diagnostic-" + str(os.getpid())
            execute("missing-daemon-" + variant,
                    [str(binary), "acquire", "--", true], env,
                    wanted_marker=variant == "observed")
        for mode in ("native", "monitored"):
            for sample, variant in enumerate(("original", "observed", "observed")):
                cli = original_cli if variant == "original" else observed_cli
                shutil.copy2(cli, active_cli)
                env = os.environ.copy()
                env["RUNQUOTA_REPORT_STANDALONE"] = "1"
                name = mode + "-" + variant + "-" + str(sample)
                command = [bash, "-c", 'timeout --kill-after=10 600 "$@" </dev/null',
                           "concurrent-clients", str(fixture_bins[variant]).replace("\\", "/")]
                if mode == "monitored":
                    env["REPRO_MONITOR_SHIM_LIB"] = str(shim)
                    command = [repro, "internal", "io", "monitor", "--depfile",
                               str(evidence / (name + ".iomon")), "--", *command]
                execute(name, command, env)
    finally:
        shutil.copy2(original_cli, active_cli)
    if hashes() != initial or subprocess.check_output(["git", "diff", "HEAD"]):
        raise RuntimeError("Diagnostic modified its inputs")
    return int(any(not row["expected"] for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
