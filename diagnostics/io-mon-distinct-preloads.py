"""Qualify real Linux image binding with an original-binding failure control."""
import json
import os
from pathlib import Path
import platform
import resource
import subprocess

root = Path.cwd()
evidence = root / "test-logs/linux-runtime"
evidence.mkdir(parents=True, exist_ok=True)
source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert source == "d344703967f9538ca5fda5a40508e4753039c4e8", source
(evidence / "source.txt").write_text(source + "\n")
config = root / "src/io_mon/shim/linux_preload.nim.cfg"
original = config.read_bytes()
flag = b'--passL:"-Wl,-Bsymbolic-functions"\n'
assert original.count(flag) == 1
# The previous run already retains the complete recursive backtrace. This
# comparison needs the real exit status, not another several-hundred-MB core.
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
results = []


def run(name, args, timeout=600):
    with (evidence / (name + ".log")).open("w") as output:
        try:
            code = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({"name": name, "exitCode": code, "argv": args})
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    print("\n".join((evidence / (name + ".log")).read_text(errors="replace").splitlines()[-20:]), flush=True)
    return code


programs = ["test_io_mon_distinct_preloads", "test_io_mon_host_fault_handlers",
            "test_io_mon_vfork_frame_state"]
if platform.machine() == "x86_64":
    programs.append("test_io_mon_propagation")
else:
    print("ARM: full capture still requires the deferred raw-syscall backend.")
for program in programs:
    assert run("compile-" + program,
               ["nim", "c", "--hints:off", "tests/linux/" + program + ".nim"]) == 0

try:
    config.write_bytes(original.replace(flag, b""))
    (evidence / "original-binding.nim.cfg").write_bytes(config.read_bytes())
    negative = run("original-binding", [str(root / "tests/linux" / programs[0])])
    config.write_bytes(original)
    (evidence / "local-binding.nim.cfg").write_bytes(original)
    fixed = [run("local-binding-" + program, [str(root / "tests/linux" / program)])
             for program in programs]
finally:
    config.write_bytes(original)

assert negative == 1, results
assert "code was 139" in (evidence / "original-binding.log").read_text(), results
assert all(code == 0 for code in fixed), results
print("Original binding crashes; image-local binding passes the real regressions.")
