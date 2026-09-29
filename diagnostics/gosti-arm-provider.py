"""Real native compiler controls; no mocks or changes to product sources."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

root = Path.cwd()
evidence = root / "build/arm-provider-evidence"
evidence.mkdir(parents=True, exist_ok=True)
results = []


def run(name, argv, env):
    with (evidence / (name + ".log")).open("w") as output:
        result = subprocess.run(argv, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=1200)
    results.append({"name": name, "argv": argv, "exitCode": result.returncode})
    print(name, result.returncode, flush=True)
    return result.returncode


baseline = dict(os.environ)
run("ambient-compiler", ["repro", "build", "--daemon=off",
    "--write-report=" + str(evidence / "ambient-report.json")], baseline)
log = (evidence / "ambient-compiler.log").read_text(errors="replace")
for index, command in enumerate(re.findall(
        r"Error: execution of an external program failed: (.+)", log)):
    # Nim wraps its whole diagnostic command in single quotes.
    if command.startswith("'") and command.endswith("'"):
        command = command[1:-1]
    argv = shlex.split(command)
    # Only replay the failed compiler, never a command selected by log prose.
    if not argv or argv[0] != "/usr/bin/aarch64-linux-gnu-gcc-13":
        raise RuntimeError("Unexpected failed command: " + repr(argv[:1]))
    for arg in argv:
        path = Path(arg)
        if path.is_absolute() and path.is_file() and path.suffix == ".c":
            shutil.copyfile(path, evidence / (str(index) + "-" + path.name))
    direct = dict(baseline)
    direct.pop("LD_PRELOAD", None)
    run("direct-failed-compiler-" + str(index), argv, direct)

profile = str(Path(os.environ["RUNNER_TEMP"]) / "reprobuild-source-shell")
compiler = subprocess.check_output(["nix", "develop", profile, "--command",
    "bash", "-c", "command -v cc"], text=True).strip()
if not compiler.startswith("/nix/store/") or not Path(compiler).is_file():
    raise RuntimeError("Source shell did not resolve a Nix compiler: " + compiler)
rooted = dict(baseline, REPRO_BOOTSTRAP_CC=compiler)
(evidence / "compiler-path.txt").write_text(compiler + "\n")
run("rooted-compiler", ["repro", "build", "--daemon=off",
    "--write-report=" + str(evidence / "rooted-report.json")], rooted)
(evidence / "results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2), flush=True)
if results[0]["exitCode"] == 0:
    print("Original provider crash was not reproduced; attribution is inconclusive.")
if results[-1]["exitCode"]:
    raise SystemExit(1)
