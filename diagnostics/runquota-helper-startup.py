"""Exercise real crash-recovery helpers across the startup handshake.

No mocks: delays change when a real helper runs, never its API results.
The original and repaired fixtures use the same daemon and monitor. A delay
after the handshake must still fail the original three-second exit check.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


BASELINE = "9f88e775f3d685d5e7f7be6e098421cb06ac49cb"
SOURCE = "tests/e2e/crash-recovery/t_e2e_runquota_client_exit_releases_lease.nim"


def main():
    evidence = Path("build/helper-startup").resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    changed = subprocess.check_output(
        ["git", "diff", "--name-only", BASELINE, "HEAD"], text=True
    ).splitlines()
    if changed != [SOURCE] or subprocess.check_output(
        ["git", "diff", "HEAD", "--", SOURCE], text=True
    ):
        raise RuntimeError("Expected exactly the committed helper fixture change")
    pins = {}
    for repo in (".", "reprobuild", "io-mon", "nim-stackable-hooks"):
        pins[repo] = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "HEAD"], text=True
        ).strip()
    (evidence / "source-pins.json").write_text(json.dumps(pins, indent=2))
    original = subprocess.check_output(
        ["git", "show", BASELINE + ":" + SOURCE], text=True
    )
    fixed = Path(SOURCE).read_text()

    def delayed(text, anchor):
        if text.count(anchor) != 1:
            raise RuntimeError("The real helper entry/gate anchor changed")
        return text.replace(
            anchor, anchor + '  if helperMode == "starting-abnormal": sleep(3500)\n'
        )

    entry = "if helperMode.len > 0:\n"
    gate = '  waitForReady(startupPath & ".go")\n'
    variants = {
        "original_entry_delay": delayed(original, entry),
        "handshake_entry_delay": delayed(fixed, entry),
        "handshake_work_delay": delayed(fixed, gate),
        "handshake": fixed,
    }
    with (evidence / "apps.build.log").open("wb") as output:
        subprocess.run(
            ["bash", "scripts/build_apps.sh"], stdout=output,
            stderr=subprocess.STDOUT, check=True,
        )
    binaries = {}
    for name, text in variants.items():
        source = evidence / (name + ".nim")
        source.write_text(text)
        binary = source.with_suffix(".exe")
        binaries[name] = binary
        with (evidence / (name + ".build.log")).open("wb") as output:
            subprocess.run(
                ["nim", "c", "--threads:on", "--cpu:amd64",
                 "--nimcache:build/helper-startup-cache/" + name,
                 "--out:" + str(binary), str(source)],
                stdout=output, stderr=subprocess.STDOUT, check=True,
            )
    shim = Path("reprobuild/build/lib/librepro_monitor_shim.dll").resolve()
    inputs = [*binaries.values(), *Path("build/bin").glob("*.exe"), shim]

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

    initial = hashes()
    (evidence / "input-sha256.json").write_text(json.dumps(initial, indent=2))
    repro, bash = shutil.which("repro"), shutil.which("bash")
    if not repro or not bash:
        raise RuntimeError("Missing activated runtime environment")
    outcomes = []
    for mode in ("native", "monitored"):
        for name, binary in binaries.items():
            if hashes() != initial:
                raise RuntimeError("A comparison binary changed")
            prefix = evidence / (mode + "-" + name)
            command = [bash, "-c", 'timeout --kill-after=10 600 "$1" </dev/null',
                       "helper-startup", str(binary).replace("\\", "/")]
            env = os.environ.copy()
            if mode == "monitored":
                env["REPRO_MONITOR_SHIM_LIB"] = str(shim)
                command = [repro, "internal", "io", "monitor", "--depfile",
                           str(prefix) + ".iomon", "--", *command]
            log = Path(str(prefix) + ".log")
            start = time.monotonic()
            expired = False
            with log.open("wb") as output:
                child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT)
                try:
                    code = child.wait(timeout=1200)
                except subprocess.TimeoutExpired:
                    expired = True
                    subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                   stdout=output, stderr=subprocess.STDOUT, timeout=30)
                    code = child.wait(timeout=30)
            text = log.read_text(errors="replace")
            negative = name in ("original_entry_delay", "handshake_work_delay")
            expected = (
                code == 1 and text.count("[FAILED]") == 1
                and text.count("[OK]") == 7
                and "Check failed: helper.waitForExit(3000) == 32" in text
            ) if negative else (code == 0 and text.count("[OK]") == 8)
            outcome = dict(mode=mode, variant=name, exitCode=code,
                           expected=expected, outerExpired=expired,
                           elapsedSeconds=time.monotonic() - start)
            outcomes.append(outcome)
            print(json.dumps(outcome), flush=True)
            (evidence / "results.json").write_text(json.dumps(outcomes, indent=2))
    if hashes() != initial:
        raise RuntimeError("A comparison binary changed during execution")
    return int(any(not r["expected"] or r["outerExpired"] for r in outcomes))


if __name__ == "__main__":
    raise SystemExit(main())
