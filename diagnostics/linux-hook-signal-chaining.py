"""Real native/monitored fixture control, with no monitor or assertion bypass.

Only the disposable C fixture's signal policy changes. Trace kernel signal
operations outside the child, never logging from a signal handler itself.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess

root = Path.cwd()
evidence = root / "build/signal-chaining"
evidence.mkdir(parents=True, exist_ok=True)
source = root / "tests/fixtures/linux_raw_syscalls_c_abi_smoke.c"
original = source.read_text()
repro = os.environ["HOOKS_SIGNAL_REPRO"]
trace = os.environ["HOOKS_SIGNAL_STRACE"]
install = "(void *)&stackable_live_int3_handler, 0);"
foreign = """    stackable_live_int3_failures++;
    (void)stackable_linux_chain_sigtrap(signo, info, uctx);
    return;"""
assert original.count(install) == original.count(foreign) == 1
nested = original.replace(install, "(void *)&stackable_live_int3_handler, SA_NODEFER);")
chained = nested.replace(foreign, """    if (stackable_linux_chain_sigtrap(signo, info, uctx) != 0)
      stackable_live_int3_failures++;
    return;""")
variants = {"original": original, "nested": nested, "nested_chained": chained}
results = []

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def run(command, output):
    with output.open("wb") as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            return child.wait(timeout=240)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=20)
            return 124

try:
    pins = {"hooks": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
            "reproPath": repro, "reproSha256": digest(repro)}
    assert pins["hooks"] == "f3a9dc18849302dbf52df349aaa4bf6c41413eed"
    (evidence / "pins.json").write_text(json.dumps(pins, indent=2))
    for name, content in variants.items():
        source.write_text(content)
        folder = evidence / name
        folder.mkdir(exist_ok=True)
        binary = folder / "raw-syscalls-test"
        code = run([shutil.which("nim"), "c", "--threads:on", "--hints:off",
                    "--nimcache:build/signal-chaining-cache/" + name,
                    "--out:" + str(binary), "tests/test_linux_raw_syscalls.nim"],
                   folder / "build.log")
        if code:
            raise RuntimeError(f"Could not compile {name}: {code}")
        initial = digest(binary)
        (folder / "fixture.c").write_text(content)
        for mode in ("native", "monitored"):
            command = [str(binary)]
            if mode == "monitored":
                command = [repro, "internal", "io", "monitor", "--depfile",
                           str(folder / "capture.iomon"), "--", *command]
            command = [trace, "-f", "-qq", "-s", "256", "-o",
                       str(folder / (mode + ".strace")), "-e",
                       "trace=rt_sigaction,rt_sigprocmask,rt_sigreturn,exit,exit_group",
                       "-e", "signal=SIGTRAP,SIGSEGV", *command]
            code = run(command, folder / (mode + ".log"))
            assert digest(binary) == initial
            result = dict(variant=name, mode=mode, exitCode=code, binarySha256=initial)
            results.append(result)
            print(json.dumps(result), flush=True)
            (evidence / "results.json").write_text(json.dumps(results, indent=2))
finally:
    source.write_text(original)
assert all(r["exitCode"] == 0 for r in results if r["mode"] == "native")
assert all(r["exitCode"] == 0 for r in results if r["variant"] == "nested_chained")
