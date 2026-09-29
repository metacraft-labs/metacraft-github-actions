"""Real native/monitored telemetry controls, with child output on failure."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / 'build/macos-telemetry-evidence'
evidence.mkdir(parents=True, exist_ok=True)
results = []

def run(name, args):
    with (evidence / (name + '.log')).open('w') as out:
        p = subprocess.run(args, stdout=out, stderr=subprocess.STDOUT, timeout=5400)
    results.append({'name': name, 'exitCode': p.returncode})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, p.returncode, flush=True)
    return p.returncode

run('sip', ['/usr/bin/csrutil', 'status'])
# Production source is untouched: build fresh apps before the complete suite,
# preserving the freshness guard and all scheduling dependencies.
run('build', ['dev-exec', 'repro', 'build', '--tool-provisioning=nix',
    '--write-report=' + str(evidence / 'build.json')])
run('complete', ['dev-exec', 'repro', 'test', '--tool-provisioning=nix',
    '--write-report=' + str(evidence / 'complete.json')])
binary = root / 'build/test-bin/t_runquota_host_macos_native_process_telemetry'
if binary.exists():
    before = hashlib.sha256(binary.read_bytes()).hexdigest()
    run('native', [str(binary)])
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == before
    (evidence / 'fixture-sha256.txt').write_text(before + '\n')
else:
    raise SystemExit('Complete graph did not produce the telemetry fixture')
if any(r['exitCode'] for r in results):
    raise SystemExit(1)
