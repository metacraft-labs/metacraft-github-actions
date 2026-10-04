"""Retain real compiler crash evidence without changing product code or gates."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import subprocess


root = Path.cwd()
evidence = root / "build/arm-provider-evidence"
evidence.mkdir(parents=True, exist_ok=True)
cores = Path(os.environ["RUNNER_TEMP"]) / "repro-arm-cores"
resource.setrlimit(resource.RLIMIT_CORE, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
results = []
baseline = dict(os.environ)


def run(name, argv, env, timeout=1200):
    with (evidence / (name + ".log")).open("w") as output:
        try:
            result = subprocess.run(argv, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
            output.write("\nDiagnostic command timed out.\n")
    results.append({"name": name, "argv": argv, "exitCode": code})
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    return code


def capture_cores():
    for core in sorted(cores.glob("core.*")):
        output = evidence / (core.name + ".backtrace.log")
        if output.exists():
            continue
        # Linux %E replaces slashes with '!'; %p is the final component.
        executable = core.name.removeprefix("core.").rsplit(".", 1)[0].replace("!", "/")
        argv = ["gdb", "-nx", "--batch", "-iex", "set auto-load off",
                "-iex", "set print frame-arguments none", "-c", str(core)]
        if Path(executable).is_file():
            argv += ["-e", executable]
        argv += ["-ex", "info files", "-ex", "info sharedlibrary",
                  "-ex", "thread apply all bt"]
        with output.open("w") as log:
            subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT,
                            timeout=120, check=False)
        # Raw memory may contain job credentials. Only the argument-free
        # backtrace leaves this disposable runner, never the core itself.
        core.unlink()


source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert source == "f369c3429c83be2403b8dd91d25e137207b30575", source
(evidence / "source.txt").write_text(source + "\n")
identity = {}
for path in [Path("/usr/bin/aarch64-linux-gnu-gcc-13"),
              root / ".reprobuild-src/build/bin/repro",
              root / ".reprobuild-src/build/lib/librepro_monitor_shim.so"]:
    if path.is_file():
        identity[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
(evidence / "binary-sha256.json").write_text(json.dumps(identity, indent=2))

for attempt in range(1, 7):
    name = "provider-" + str(attempt)
    # First run is exactly the ordinary CI command, including daemon selection.
    args = ["dev-exec", "repro", "build", "--tool-provisioning=nix"]
    if attempt > 1:
        args += ["--work-root=" + str(root / (".repro-arm-provider-" + str(attempt))),
                  "--write-report=" + str(evidence / (name + ".json"))]
    code = run(name, args, baseline)
    log = (evidence / (name + ".log")).read_text(errors="replace")
    capture_cores()
    for index, command in enumerate(re.findall(r"Error: execution of an external program failed: (.+)", log)):
        if command.startswith("'") and command.endswith("'"):
            command = command[1:-1]
        argv = shlex.split(command)
        if not argv or argv[0] != "/usr/bin/aarch64-linux-gnu-gcc-13":
            raise RuntimeError("Unexpected failed compiler: " + repr(argv[:1]))
        for arg in argv:
            path = Path(arg)
            if path.is_absolute() and path.is_file() and path.suffix == ".c":
                shutil.copyfile(path, evidence / (name + "-" + str(index) + "-" + path.name))
        # Diagnostic comparison only: production builds above remain monitored.
        direct = dict(baseline)
        direct.pop("LD_PRELOAD", None)
        run(name + "-direct-compiler-" + str(index), argv, direct)
        capture_cores()
    if code:
        print("\n".join(log.splitlines()[-25:]), flush=True)
        break

print(json.dumps(results, indent=2), flush=True)
if all(result["exitCode"] == 0 for result in results):
    print("All six monitored provider builds passed; cause attribution uses the separate runtime controls.")
else:
    raise SystemExit(1)
