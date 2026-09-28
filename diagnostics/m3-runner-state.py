"""Bounded, read-only diagnosis of m3-mcl-001's repeated lost jobs.

Print no job payloads, credentials, environment blocks or process arguments.
Only runner-owned diagnostic files are read. No service or process is changed.
"""

import collections
import datetime
import os
from pathlib import Path
import re
import subprocess


runner = os.environ.get("RUNNER_NAME", "")
if runner not in {f"m3-mcl-{number:03d}" for number in range(1, 7)}:
    raise SystemExit("Refusing diagnostics outside the persistent m3 fleet")
print("diagnostic_runner=" + runner, flush=True)


def command(argv):
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=15)
        return result.stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return type(error).__name__


print(command(["/usr/bin/uptime"]))
print(command(["/bin/df", "-h", "/private/var/lib/github-runners"]))
print(command(["/usr/bin/vm_stat"]).splitlines()[:12])
for line in command(["/bin/ps", "-axo", "pid,ppid,user,nice,pri,stat,etime,comm"]).splitlines():
    if re.search(r"/Runner\.(Listener|Worker)$", line):
        print("runner_process " + line[:400])

service = command(["/bin/launchctl", "print",
                   "system/org.nixos.github-runner-mcl-001"])
for line in service.splitlines():
    if re.match(r"\s*(state|pid|runs|last exit code|last terminating signal) =", line):
        print("service " + line.strip())

root = Path("/private/var/lib/github-runners/mcl-001/_diag")
print("diagnostic_root=" + str(root))
if not root.is_dir():
    raise SystemExit("Expected runner diagnostic directory is unavailable")

# A timestamped severity/component prefix excludes job JSON, raw headers and
# multiline payloads. Messages are capped and scrubbed again before output.
prefix = re.compile(r"^\[([^\]]+) (ERR|WARN|INFO) ([A-Za-z0-9_.]+)\] (.*)$")
interesting = re.compile(
    r"Exception|error|failed|timed out|Worker process|worker process|"
    r"Job message|job message|Running job|Job completed|Renew.*job|"
    r"Process started|Starting process|Process completed|session.*expired",
    re.IGNORECASE)


def sanitize(message):
    if re.search(r"token|password|secret|authorization|credential|bearer", message, re.IGNORECASE):
        return "<credential-related message omitted>"
    message = re.sub(r"https?://\S+", "<url>", message)
    message = re.sub(r"(?i)(token|password|secret|authorization|credential)\s*[:=]\s*\S+",
                     r"\1=<redacted>", message)
    message = re.sub(r"\b(?:gh[a-z]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b",
                     "<redacted>", message)
    message = re.sub(r"\b[A-Za-z0-9_+/=-]{80,}\b", "<opaque-value>", message)
    return message[:500]


for pattern in ("Runner_*.log", "Worker_*.log"):
    files = sorted(root.glob(pattern), key=lambda path: path.stat().st_mtime)[-1:]
    print("matching_recent_files=" + str(len(files)))
    for path in files:
        stat = path.stat()
        print("file", path.name, "bytes", stat.st_size, "modified",
              datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).isoformat())
        # Read only the final 2 MiB, with a 60-line output bound per file.
        with path.open("rb") as source:
            if stat.st_size > 2 * 1024 * 1024:
                source.seek(stat.st_size - 2 * 1024 * 1024)
                source.readline()
            lines = source.read().decode("utf-8", errors="replace").splitlines()
        counts = collections.Counter()
        selected = collections.deque(maxlen=140)
        for line in lines:
            match = prefix.match(line)
            if not match:
                continue
            timestamp, severity, component, message = match.groups()
            counts[(severity, component)] += 1
            if (severity in {"ERR", "WARN"} or interesting.search(message) or
                    (pattern.startswith("Runner") and component in
                     {"JobDispatcher", "ProcessInvokerWrapper", "ProcessChannel"})):
                selected.append(f"{timestamp} {severity} {component} {sanitize(message)}")
        print("severity_components", dict(counts))
        for line in selected:
            print(line)
