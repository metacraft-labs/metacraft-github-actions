"""Real native/monitored telemetry controls, with child output on failure."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / 'build/macos-telemetry-evidence'
evidence.mkdir(parents=True, exist_ok=True)
fixture = root / 'libs/runquota_host_macos/tests/t_runquota_host_macos_native_process_telemetry.nim'
original = fixture.read_text()
results = []

def run(name, args):
    with (evidence / (name + '.log')).open('w') as out:
        p = subprocess.run(args, stdout=out, stderr=subprocess.STDOUT, timeout=1800)
    results.append({'name': name, 'exitCode': p.returncode})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, p.returncode, flush=True)
    return p.returncode

run('sip', ['/usr/bin/csrutil', 'status'])
run('original-monitored', ['repro', 'build', '--daemon=off', '--tool-provisioning=nix',
    '.#test-t_runquota_host_macos_native_process_telemetry',
    '--write-report=' + str(evidence / 'original-report.json')])
changed = original.replace('when defined(macosx):\n  type',
    'when defined(macosx):\n  var diagnosticChildren: seq[tuple[mode: string, child: Process]]\n  type', 1)
changed = changed.replace('options = {poStdErrToStdOut}\n      )',
    'options = {poParentStreams}\n      )\n      diagnosticChildren.add((mode, result))', 1)
changed = changed.replace('    if not fileExists(path):\n      raise newException',
    '    if not fileExists(path):\n      for entry in diagnosticChildren:\n'
    '        echo "fixture mode=", entry.mode, " pid=", entry.child.processID,\n'
    '          " exit=", entry.child.peekExitCode()\n      raise newException', 1)
assert changed != original and 'diagnosticChildren.add' in changed
try:
    fixture.write_text(changed)
    (evidence / 'child-diagnostics.patch').write_text(subprocess.check_output(['git', 'diff', '--', str(fixture)], text=True))
    for attempt in range(1, 6):
        name = 'diagnostic-monitored-' + str(attempt)
        run(name, ['repro', 'build', '--daemon=off', '--tool-provisioning=nix',
            '--force-rebuild', '.#test-t_runquota_host_macos_native_process_telemetry',
            '--write-report=' + str(evidence / (name + '.json'))])
    binary = root / 'build/test-bin/t_runquota_host_macos_native_process_telemetry'
    before = hashlib.sha256(binary.read_bytes()).hexdigest()
    run('diagnostic-native', [str(binary)])
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == before
    (evidence / 'fixture-sha256.txt').write_text(before + '\n')
finally:
    fixture.write_text(original)
print(json.dumps(results, indent=2), flush=True)
if any(r['exitCode'] for r in results):
    raise SystemExit(1)
