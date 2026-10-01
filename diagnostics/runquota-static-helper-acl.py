"""Check real Windows scratch-directory permissions and the complete helper gate.

No mocks: controls change actual DACLs using the OS tool. The original and fixed
setup fragments come from the exact source revisions. A foreign-grant control
then exercises the unchanged gate's refusal before the full repaired gate runs.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

BASELINE = "d6ee4588f71604376a4cc41ef281d6c479395efc"
REVISION = "2d07c5de63a24c4869ceddda78c14bbf38b76271"
SCRIPT = "scripts/static_helper_gate_toolstore.sh"
FOREIGN = "S-1-5-11"


def main():
    evidence = Path("build/static-helper-acl-evidence").resolve()
    evidence.mkdir(parents=True)
    if os.name != "nt" or ctypes.windll.kernel32.GetCurrentProcessId() != os.getpid():
        raise RuntimeError("The timeout controller requires native Windows Python process IDs")
    pins = {name: subprocess.check_output(
        ["git", "-C", name, "rev-parse", "HEAD"], text=True).strip()
        for name in (".", "reprobuild", "io-mon", "nim-stackable-hooks")}
    assert pins["."] == REVISION, pins
    changed = subprocess.check_output(
        ["git", "diff", "--name-only", BASELINE, "HEAD", "--", ".", ":!issues/**"],
        text=True).splitlines()
    assert changed == [SCRIPT], changed
    assert not subprocess.check_output(["git", "diff", "HEAD", "--", SCRIPT])
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    (evidence / "source-change.patch").write_bytes(subprocess.check_output(
        ["git", "diff", BASELINE, "HEAD", "--", SCRIPT]))
    original = subprocess.check_output(["git", "show", BASELINE + ":" + SCRIPT]).decode()
    path = Path(SCRIPT)
    fixed_bytes = path.read_bytes()
    fixed = fixed_bytes.decode()
    (evidence / "source-hashes.json").write_text(json.dumps({
        "original": hashlib.sha256(original.encode()).hexdigest(),
        "fixed": hashlib.sha256(fixed_bytes).hexdigest(),
        "guard": hashlib.sha256(Path("scripts/static_helper_gate_toolstore.nim").read_bytes()).hexdigest(),
    }, indent=2))
    bash = shutil.which("bash")
    if not bash or "GNU bash" not in subprocess.check_output([bash, "--version"], text=True):
        raise RuntimeError("Missing activated GNU Bash")
    capture = Path(__file__).with_suffix(".ps1").resolve()
    results = []

    def save():
        (evidence / "results.json").write_text(json.dumps(results, indent=2))

    def run(name, args, timeout):
        start = time.monotonic()
        with (evidence / (name + ".log")).open("wb") as log:
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
            timed_out = False
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                subprocess.run([str(Path(os.environ["SYSTEMROOT"]) / "System32/taskkill.exe"),
                                "/PID", str(process.pid), "/T", "/F"], stdout=log, stderr=log,
                               timeout=60, check=False)
                code = process.wait(timeout=30)
        result = {"name": name, "exitCode": code, "timedOut": timed_out,
                  "seconds": round(time.monotonic() - start, 2)}
        results.append(result)
        save()
        assert not timed_out, result
        return result

    def foreign_grants(acl):
        allowed = {acl["account"], "S-1-5-18", "S-1-5-32-544"}
        return [entry for entry in acl["entries"]
                if entry["type"] == "Allow" and entry["sid"] not in allowed]

    prefix = r'''#!/usr/bin/env bash
set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
repo_root="$(cygpath -u "$1")"
capture="$(cygpath -u "$2")"
system32="$(cygpath -u "${SYSTEMROOT:-$SystemRoot}")/System32"
system_icacls="${system32}/icacls.exe"
system_whoami="${system32}/whoami.exe"
system_powershell="${system32}/WindowsPowerShell/v1.0/powershell.exe"
record_acl() {
  "$system_powershell" -NoProfile -NonInteractive -File "$(cygpath -w "$capture")" \
    -Directory "$(cygpath -w "$work_root")" -OutputFile "$(cygpath -w "$repo_root/$1.json")"
}
'''
    forced = r'''mkdir -p "${work_root}"
"${system_icacls}" "$(cygpath -w "${work_root}")" //grant "*S-1-5-11:F"
record_acl before
'''
    for variant, source in (("original", original), ("fixed", fixed)):
        case = evidence / ("acl-" + variant)
        case.mkdir()
        start = source.index('work_root="${repo_root}/build/static-helper-gate"')
        stop = source.index('nim_root="${work_root}/toolchain/nim"', start)
        fragment = source[start:stop]
        assert fragment.count('mkdir -p "${work_root}"\n') == 1
        fragment = fragment.replace('mkdir -p "${work_root}"\n', forced, 1)
        control = case / "setup.sh"
        control.write_text(prefix + fragment + "record_acl after\n", newline="\n")
        result = run("acl-" + variant, [bash, control.as_posix(), case.as_posix(), capture.as_posix()], 120)
        assert result["exitCode"] == 0, result
        before = json.loads((case / "before.json").read_text(encoding="utf-8-sig"))
        after = json.loads((case / "after.json").read_text(encoding="utf-8-sig"))
        assert any(e["sid"] == FOREIGN and not e["inherited"] for e in foreign_grants(before)), before
        assert after["owner"] in {after["account"], "S-1-5-32-544"}, after
        assert after["protected"], after
        foreign = foreign_grants(after)
        assert (bool(foreign) if variant == "original" else not foreign), after
        result["expectedOutcome"] = "foreign grant retained" if variant == "original" else "private DACL"
        result["expectedOutcomePassed"] = True
        save()

    # Grant access after the trusted driver is compiled, before it checks the
    # real root. Its source and privacy predicate remain unchanged.
    marker = 'authority_file="${work_root}/authority.txt"'
    assert fixed.count(marker) == 1
    negative = fixed.replace(marker,
        '"${system_icacls}" "$(cygpath -w "${work_root}")" //grant "*S-1-5-11:F" >/dev/null\n' + marker, 1)
    (evidence / "negative-script.sh").write_text(negative, newline="\n")
    try:
        path.write_text(negative, newline="\n")
        result = run("guard-negative", [bash, SCRIPT], 900)
        log = (evidence / "guard-negative.log").read_text(errors="replace")
        assert result["exitCode"] != 0, result
        assert "gate work root grants S-1-5-11 access" in log, log[-3000:]
        result["expectedOutcome"] = "unchanged guard rejects actual foreign grant"
        result["expectedOutcomePassed"] = True
        save()
    finally:
        path.write_bytes(fixed_bytes)
    assert not subprocess.check_output(["git", "diff", "HEAD", "--", SCRIPT])
    result = run("fixed-full-gate", [bash, SCRIPT], 3600)
    log = (evidence / "fixed-full-gate.log").read_text(errors="replace")
    assert result["exitCode"] == 0, result
    assert "runquota static helper checks passed (tool-store authority," in log, log[-3000:]
    result["expectedOutcome"] = "complete gate passes"
    result["expectedOutcomePassed"] = True
    save()
    print(json.dumps({"source": REVISION, "expectedOutcomesPassed": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main()
