"""Compare the exact real vfork probe with its enclosing-monitor execution."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess

root = Path.cwd()
evidence = root / "test-logs/repro-frame"
evidence.mkdir(parents=True, exist_ok=True)
assert subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == "d344703967f9538ca5fda5a40508e4753039c4e8"
resource.setrlimit(resource.RLIMIT_CORE, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
cores = Path(os.environ["RUNNER_TEMP"]) / "io-frame-cores"
recipe = root / "repro.nim"
fixture = root / "tests/linux/test_io_mon_vfork_frame_state.nim"
originals = {p: p.read_bytes() for p in (recipe, fixture)}
results = []


def run(name, args, env=None, timeout=1200):
    with (evidence / (name + ".log")).open("w") as output:
        try:
            code = subprocess.run(args, env=env, stdout=output, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({"name": name, "exitCode": code, "argv": args})
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    if code:
        print("\n".join((evidence / (name + ".log")).read_text(errors="replace").splitlines()[-25:]), flush=True)
    return code


def backtraces():
    for core in cores.glob("core.*"):
        executable = core.name.removeprefix("core.").rsplit(".", 1)[0].replace("!", "/")
        with (evidence / (core.name + ".backtrace.log")).open("w") as output:
            subprocess.run(["gdb", "-nx", "--batch", "-iex", "set auto-load off",
                "-iex", "set print frame-arguments none", "-c", str(core), "-e", executable,
                "-ex", "info sharedlibrary", "-ex", "thread apply all bt"],
                stdout=output, stderr=subprocess.STDOUT, timeout=120, check=False)
        core.unlink()


try:
    source = recipe.read_text()
    anchor = '    discard collect("test", testExecuteActions)'
    assert source.count(anchor) == 1
    alias = '''
    var diagnosticFrame: seq[BuildActionDef] = @[]
    for action in testExecuteActions:
      if action.id == "io-mon.test_execute.test_io_mon_vfork_frame_state":
        diagnosticFrame.add(action)
    doAssert diagnosticFrame.len == 1
    discard collect("diagnostic-frame", diagnosticFrame)'''
    recipe.write_text(source.replace(anchor, anchor + alias))
    source = fixture.read_text()
    assert source.count('    defer: removeDir(work)') == 1
    source = source.replace('    defer: removeDir(work)', '    echo "diagnostic retained work: ", work')
    # unittest checkpoints print only on failure. Expose the actual captured C
    # output on success too, without changing the original fixture assertions.
    assert source.count('    checkpoint(observed.output)') == 1
    source = source.replace('    checkpoint(observed.output)',
                            '    echo observed.output\n    checkpoint(observed.output)')
    for before, after in [
        ('  alarm(30);', '  alarm(30);\n  puts("probe phase: main"); fflush(stdout);'),
        ('  void *before = frame();', '  puts("probe phase: before frame query and vfork"); fflush(stdout);\n  void *before = frame();'),
        ('  void *after = frame();', '  void *after = frame();\n  puts("probe phase: after frame query"); fflush(stdout);'),
    ]:
        assert source.count(before) == 1
        source = source.replace(before, after)
    fixture.write_text(source)
    (evidence / "diagnostic.patch").write_text(subprocess.check_output(
        ["git", "diff", "--", "repro.nim", str(fixture)], text=True))
    run("monitored", ["dev-exec", "repro", "build", ".#diagnostic-frame",
        "--tool-provisioning=nix", "--force-rebuild", "--write-report=" + str(evidence / "report.json")])
    backtraces()
    assert (evidence / "report.json").exists(), "Provider failed before the frame action; inspect monitored.log"
    report = json.loads((evidence / "report.json").read_text())
    actions = [a for a in report["actions"] if a["id"].startswith("io-mon.test_execute.")]
    assert len(actions) == 1 and actions[0]["launched"], actions
    action = actions[0]
    (evidence / "action-output.log").write_text(action["stdout"] + action.get("stderr", ""))
    retained = re.search(r"diagnostic retained work: (.+)", action["stdout"])
    assert retained, action
    work = Path(retained[1].strip())
    probe = work / "probe"
    shim = work / "lib/librepro_monitor_shim.so"
    identity = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (probe, shim)}
    (evidence / "probe-sha256.json").write_text(json.dumps(identity, indent=2))
    # The SAME ELF and shim, now outside the enclosing action. The completed
    # outer session is not recreated; this is an explicit diagnostic control.
    direct = dict(os.environ, LD_PRELOAD=str(shim), REPRO_MONITOR_SHIM_LIB=str(shim))
    direct_code = run("direct-same-probe", [str(probe)], env=direct, timeout=60)
    backtraces()
    for p in (probe, shim):
        assert hashlib.sha256(p.read_bytes()).hexdigest() == identity[str(p)]
    print((evidence / "action-output.log").read_text()[-2500:])
    assert direct_code == 0, results
    assert action["status"] == "asSucceeded" and action["exitCode"] == 0, action
    assert "vfork frame state: before-null=1 after-null=1" in action["stdout"], action
finally:
    for p, contents in originals.items():
        p.write_bytes(contents)
