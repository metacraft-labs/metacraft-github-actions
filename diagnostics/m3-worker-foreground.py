"""Reversible scheduling control for one verified idle macOS runner.

No process is killed or restarted. No service file is changed. The original
nice value is logged; background policy can be restored with taskpolicy -b.
The durable control-process policy belongs to infra/services/github-runners.
"""

import os
import re
import subprocess
import sys


def command(argv):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=10)


if os.geteuid() != 0:
    raise SystemExit("This scheduling control requires root")
if len(sys.argv) != 2 or sys.argv[1] not in {
        f"m3-mcl-{number:03d}" for number in range(2, 7)}:
    raise SystemExit("Run the control from another persistent Metacraft m3 runner")

service = "system/org.nixos.github-runner-mcl-001"
state = command(["/bin/launchctl", "print", service])
match = re.search(r"^\s*pid = (\d+)\s*$", state, re.MULTILINE)
if not match or "state = running" not in state:
    raise SystemExit("The expected service is not running")
service_pid = int(match.group(1))


def snapshot():
    rows = {}
    for line in command(["/bin/ps", "-axo", "pid,ppid,user,nice,lstart,comm"]).splitlines()[1:]:
        fields = line.split(None, 9)
        if len(fields) == 10:
            rows[int(fields[0])] = (int(fields[1]), fields[2], int(fields[3]),
                                    " ".join(fields[4:9]), fields[9])
    return rows


rows = snapshot()
parent = rows.get(service_pid)
if parent is None or parent[1] != "_github-runner-mcl" or not parent[4].endswith("/bin/bash"):
    raise SystemExit("Service process identity does not match the diagnosed launcher")
listeners = [pid for pid, row in rows.items()
             if row[0] == service_pid and row[1] == "_github-runner-mcl"
             and row[4].endswith("/lib/github-runner/Runner.Listener")]
if len(listeners) != 1:
    raise SystemExit("Expected exactly one listener under the diagnosed service")
listener = listeners[0]
if any(row[0] == listener for row in rows.values()):
    raise SystemExit("Listener has an active child; leave its worker untouched")
targets = [service_pid, listener]
for pid in targets:
    if rows[pid][2] not in (0, 5):
        raise SystemExit("Unexpected scheduling policy; refusing to change it")
    print("before", pid, rows[pid], flush=True)

# Recheck PID, parent, owner, start time and executable before applying the
# narrow policy adjustment. Do not act on stale diagnostic PIDs.
current = snapshot()
if any(current.get(pid) != rows[pid] for pid in targets):
    raise SystemExit("Service process identity changed during diagnosis")
if any(row[0] == listener for row in current.values()):
    raise SystemExit("A worker started during diagnosis; refusing the adjustment")
for pid in targets:
    print(command(["/usr/bin/taskpolicy", "-B", "-p", str(pid)]), end="")
print(command(["/usr/bin/renice", "-n", "0", "-p", *map(str, targets)]), end="")
after = snapshot()
for pid in targets:
    row = after.get(pid)
    if row is None or row[:2] != rows[pid][:2] or row[3:] != rows[pid][3:] or row[2] != 0:
        raise SystemExit("Post-adjustment identity or nice verification failed")
    print("after", pid, row, flush=True)
print("Existing idle service preserved; foreground worker-handoff probe is required")
