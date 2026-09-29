#!/usr/bin/env python3
"""Compare real Reprobuild executions of identical Linux test binaries.

No mocks: use the product recipe, source dependencies, compiler and monitor.
The temporary recipe edit changes only execution monitoring for the five
isolated programs. Always restore it, including when the negative control fails.
"""

import hashlib
import json
from pathlib import Path
import subprocess


STEMS = (
    "test_io_mon_host_session_scope",
    "test_io_mon_evidence_scope_older_shim",
    "test_io_mon_evidence_scope_shim_gate",
    "test_io_mon_library_load_closure",
    "test_io_mon_linux_fragment_fd_reuse",
)
EXPECTED = {"io-mon.test_execute." + stem for stem in STEMS}
BUILD = Path("build")
BUILD.mkdir(exist_ok=True)


def invoke(name, target):
    report = BUILD / ("diagnostic-" + name + ".json")
    command = ["repro", "build", "--daemon=off", "--tool-provisioning=nix",
               target, "--write-report=" + str(report)]
    result = subprocess.run(command, check=False)
    assert report.is_file(), f"Missing {name} report; command exited {result.returncode}"
    return result.returncode, json.loads(report.read_text())


def verify_execution(report, status, policy):
    runs = [a for a in report["actions"] if a["id"].startswith("io-mon.test_execute.")]
    assert {a["id"] for a in runs} == EXPECTED, [a["id"] for a in runs]
    for action in runs:
        assert action["launched"] and action["status"] == status, action["id"]
        assert action["dependencyPolicyKind"] == policy, action["id"]
        assert (action["exitCode"] == 0) == (status == "asSucceeded"), action["id"]
        print(status, action["id"], flush=True)


def hashes():
    return {stem: hashlib.sha256((BUILD / "test-bin" / stem).read_bytes()).hexdigest()
            for stem in STEMS}


code, full = invoke("test", ".#test")
assert code == 0, "Complete product graph failed"
before = hashes()
(BUILD / "diagnostic-binary-hashes.json").write_text(json.dumps(before, indent=2) + "\n")

code, repeat = invoke("isolation-repeat", ".#test-monitor-isolation")
assert code == 0, "Repeated isolated programs failed"
verify_execution(repeat, "asSucceeded", "dgRecognizedFormat")
assert hashes() == before, "Repeated execution changed a compiled binary"

recipe = Path("repro.nim")
original = recipe.read_text()
needle = '      if isolatesMonitor:\n        let depfile = '
assert original.count(needle) == 1
try:
    recipe.write_text(original.replace(needle,
        '      if isolatesMonitor and not defined(linux):\n        let depfile = '))
    code, monitored = invoke("outer-monitor-control", ".#test-monitor-isolation")
    assert code != 0, "Outer monitor unexpectedly passed the negative control"
    verify_execution(monitored, "asFailed", "dgAutomaticMonitor")
    assert hashes() == before, "The monitored control changed a compiled binary"
finally:
    recipe.write_text(original)

code, restored = invoke("isolation-restored", ".#test-monitor-isolation")
assert code == 0, "Restored isolated execution failed"
verify_execution(restored, "asSucceeded", "dgRecognizedFormat")
assert hashes() == before, "Restored execution changed a compiled binary"
print("Complete graph and repeated executions pass; identical binaries fail under the outer monitor.", flush=True)
