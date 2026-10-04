"""Run real Linux regression binaries against independently built shim settings."""
import json
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / "test-logs/linux-runtime"
evidence.mkdir(parents=True, exist_ok=True)
source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert source == "00a62863198c08f608c2ec3275a2af930536306b", source
(evidence / "source.txt").write_text(source + "\n")
config = root / "src/io_mon/shim/linux_preload.nim.cfg"
original = config.read_bytes()
results = []


def run(name, args, timeout=600):
    with (evidence / (name + ".log")).open("w") as log:
        try:
            code = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            code = 124
            log.write("\nDIAGNOSTIC TIMEOUT\n")
    results.append({"name": name, "exitCode": code})
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    return code


programs = ["test_io_mon_propagation", "test_io_mon_host_fault_handlers"]
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
        for program in programs:
            run(name + "-" + program, [str(root / "tests/linux" / program)])
finally:
    config.write_bytes(original)

required = [r for r in results if r["name"].startswith("posix-policy-")]
assert len(required) == 2
assert all(r["exitCode"] == 0 for r in required), required
negative = next(r for r in results if r["name"] ==
                "old-orc-traces-handlers-test_io_mon_host_fault_handlers")
assert negative["exitCode"] not in (0, 124), negative
print("Production settings pass; old settings fail the real host-handler control.")
