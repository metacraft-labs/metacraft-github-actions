"""Capture real native provider/compiler crashes; no product-source changes."""
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import subprocess

root = Path.cwd()
evidence = root / 'build/arm-provider-evidence'
evidence.mkdir(parents=True, exist_ok=True)
resource.setrlimit(resource.RLIMIT_CORE, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
results = []
baseline = dict(os.environ)
(evidence / 'selected-environment.json').write_text(json.dumps({k: v for k, v in baseline.items() if k in ['CC','REPRO_BOOTSTRAP_CC','REPRO_MONITOR_SHIM_LIB','LD_PRELOAD','REPROBUILD_BOOTSTRAP_CC','REPROBUILD_SOURCE_ROOT']}, indent=2))

def run(name, argv, env):
    with (evidence / (name + '.log')).open('w') as output:
        result = subprocess.run(argv, env=env, stdout=output,
                                stderr=subprocess.STDOUT, timeout=1200)
    results.append({'name': name, 'argv': argv, 'exitCode': result.returncode})
    print(name, result.returncode, flush=True)
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    return result.returncode

for attempt in range(1, 4):
    name = 'provider-' + str(attempt)
    args = ['repro', 'build', '--daemon=off', '--tool-provisioning=nix',
            '--write-report=' + str(evidence / (name + '.json'))]
    if attempt > 1:
        args += ['--work-root=' + str(evidence / ('fresh-work-' + str(attempt)))]
    run(name, args, baseline)
    log = (evidence / (name + '.log')).read_text(errors='replace')
    for index, command in enumerate(re.findall(r'Error: execution of an external program failed: (.+)', log)):
        if command.startswith("'") and command.endswith("'"):
            command = command[1:-1]
        argv = shlex.split(command)
        if not argv or argv[0] != '/usr/bin/aarch64-linux-gnu-gcc-13':
            raise RuntimeError('Unexpected failed compiler: ' + repr(argv[:1]))
        for arg in argv:
            path = Path(arg)
            if path.is_absolute() and path.is_file() and path.suffix == '.c':
                shutil.copyfile(path, evidence / (name + '-' + str(index) + '-' + path.name))
        direct = dict(baseline)
        direct.pop('LD_PRELOAD', None)
        run(name + '-direct-compiler-' + str(index), argv, direct)
    for core in sorted(evidence.glob('core.*')):
        out = evidence / (core.name + '.backtrace.log')
        if out.exists():
            continue
        with out.open('w') as output:
            subprocess.run(['gdb', '-nx', '--batch', '-iex', 'set auto-load off',
                            '-c', str(core), '-ex', 'info files', '-ex', 'info sharedlibrary',
                            '-ex', 'thread apply all bt'], stdout=output,
                           stderr=subprocess.STDOUT, timeout=120, check=False)
print(json.dumps(results, indent=2), flush=True)
if all(r['exitCode'] == 0 for r in results):
    print('Provider crash not reproduced; no root cause established.')
else:
    raise SystemExit(1)
