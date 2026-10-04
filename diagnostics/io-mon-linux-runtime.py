"""Run real Linux regression binaries against independently built shim settings."""
import json
import os
import platform
import resource
import shlex
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / "test-logs/linux-runtime"
evidence.mkdir(parents=True, exist_ok=True)
source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert source == "28f5995e3c19a23db74840f45384287acd2c1661", source
(evidence / "source.txt").write_text(source + "\n")
config = root / "src/io_mon/shim/linux_preload.nim.cfg"
original = config.read_bytes()
results = []
resource.setrlimit(resource.RLIMIT_CORE, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
cores = Path(os.environ["RUNNER_TEMP"]) / "io-runtime-cores"
shim_source = root / "src/io_mon/shim/linux_preload.nim"
shim_original = shim_source.read_bytes()
fault_test = root / "tests/linux/test_io_mon_host_fault_handlers.nim"
fault_original = fault_test.read_bytes()
# Retain the diagnostic child's ELF and private shim until GDB has read them.
# This changes cleanup only; the actual fixture assertions and signals stay.
fault_test.write_bytes(fault_original.replace(b"    defer: removeDir(work)",
    b'    echo "diagnostic retained work: ", work'))
(evidence / "fixture-cleanup.patch").write_text(subprocess.check_output(
    ["git", "diff", "--", str(fault_test)], text=True))


def run(name, args, timeout=600, env=None):
    with (evidence / (name + ".log")).open("w") as log:
        try:
            code = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=False, env=env).returncode
        except subprocess.TimeoutExpired:
            code = 124
            log.write("\nDIAGNOSTIC TIMEOUT\n")
    results.append({"name": name, "exitCode": code})
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    for core in cores.glob("core.*"):
        executable = core.name.removeprefix("core.").rsplit(".", 1)[0].replace("!", "/")
        with (evidence / (name + "-" + core.name + ".backtrace.log")).open("w") as trace:
            subprocess.run(["gdb", "-nx", "--batch", "-iex", "set auto-load off",
                "-iex", "set print frame-arguments none", "-c", str(core),
                "-e", executable, "-ex", "info sharedlibrary", "-ex", "thread apply all bt"],
                stdout=trace, stderr=subprocess.STDOUT, timeout=120, check=False)
        core.unlink()
    return code


programs = ["test_io_mon_host_fault_handlers"]
if platform.machine() == "x86_64":
    programs.append("test_io_mon_propagation")
else:
    # This supplemental ARM experiment measures the runtime only. io-mon's
    # full propagation suite still requires complete raw-syscall capability,
    # which ARM does not implement. Its existing assertions stay unchanged.
    print("ARM: full propagation requires the deferred raw-syscall backend.")
subprocess.run(shlex.split(os.environ.get("CC", "cc")) +
    [str(root / ".diagnostic-tools/diagnostics/io-mon-vfork-frame.c"), "-ldl",
     "-o", str(evidence / "vfork-frame")], check=True)
true_binary = subprocess.check_output(["sh", "-c", "command -v true"], text=True).strip()
# Use an actual executable, rather than the shell builtin returned above.
true_binary = "/usr/bin/true"

for program in programs:
    if run("compile-" + program, ["nim", "c", "--hints:off",
                                  "tests/linux/" + program + ".nim"]):
        raise SystemExit(1)

try:
    for name, settings in [
        ("old-orc-traces-handlers", b""),
        ("arc-only", b"--mm:arc\n"),
        ("orc-no-traces-handlers", b"--stackTrace:off\n--lineTrace:off\n-d:noSignalHandler\n--mm:orc\n"),
        ("posix-policy", original),
    ]:
        config.write_bytes(settings)
        (evidence / (name + ".nim.cfg")).write_bytes(settings)
        shim_source.write_bytes(shim_original + b"\nproc io_mon_diagnostic_frame_state(): pointer {.exportc, dynlib, stackTrace: off, raises: [].} =\n  cast[pointer](getFrame())\n")
        if run(name + "-build-frame-shim", ["bash", "scripts/build_shim.sh"]):
            raise RuntimeError("Cannot build diagnostic shim")
        environment = dict(os.environ)
        environment["LD_PRELOAD"] = str(root / "build/lib/librepro_monitor_shim.so")
        environment["REPRO_MONITOR_SHIM_LIB"] = environment["LD_PRELOAD"]
        run(name + "-frame-state", [str(evidence / "vfork-frame"), true_binary], env=environment)
        shim_source.write_bytes(shim_original)
        for program in programs:
            run(name + "-" + program, [str(root / "tests/linux" / program)])
finally:
    config.write_bytes(original)
    shim_source.write_bytes(shim_original)
    fault_test.write_bytes(fault_original)

required = [r for r in results if r["name"].startswith("posix-policy-")]
assert len(required) == len(programs) + 2
assert all(r["exitCode"] == 0 for r in required), required
negative = next(r for r in results if r["name"] ==
                "old-orc-traces-handlers-test_io_mon_host_fault_handlers")
assert negative["exitCode"] not in (0, 124), negative
print("Production settings pass; old settings fail the real host-handler control.")
