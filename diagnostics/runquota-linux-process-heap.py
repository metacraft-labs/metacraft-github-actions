"""Real production fixture, identical binary, native and source-paired monitors."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / 'build/linux-process-heap'
evidence.mkdir(parents=True, exist_ok=True)
results = []

def run(name, args, *, cwd=root, env=None, required=True):
    with (evidence / (name + '.log')).open('w') as out:
        try:
            proc = subprocess.run(args, cwd=cwd, env=env, stdout=out,
                                  stderr=subprocess.STDOUT, timeout=600)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({'name': name, 'exitCode': code})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    if required and code:
        raise SystemExit(name + ' failed; retained complete output')

stem = 't_m5_process_exec_bench_contract'
recipe = root / 'repro.nim'
original = recipe.read_text()
anchor = '    testSources.sort()'
assert original.count(anchor) == 1
filtered = original.replace(anchor, anchor + '''
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename.changeFileExt("") == "t_m5_process_exec_bench_contract":
        focusedSources.add(source)
    testSources = focusedSources''')
filtered = filtered.replace('actionId = "runquota.test_execute." & name)',
    'actionId = "runquota.test_execute." & name, cacheable = false)')
try:
    recipe.write_text(filtered)
    run('original-graph', ['dev-exec', 'repro', 'test', '--daemon=off',
        '--tool-provisioning=nix', '--write-report=' + str(evidence / 'graph.json')],
        required=False)
finally:
    recipe.write_text(original)
binary = root / 'build/test-bin' / stem
assert binary.is_file(), 'Real production fixture did not compile'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
monitor = root / '.io-mon'
run('current-monitor-build', ['nix', 'develop', '--command', 'just', 'build'], cwd=monitor)
old = root / 'build/old-monitor'
old.mkdir(parents=True, exist_ok=True)
archive = subprocess.check_output(['git', 'archive', '4b2bb3910283bac4d109012411e42ce67f9c969c'], cwd=monitor)
subprocess.run(['tar', '-xf', '-', '-C', str(old)], input=archive, check=True)
old_env = dict(os.environ, IO_MON_SHIM_OUT_DIR=str(evidence / 'old-shim'),
               IO_MON_SHIM_NIMCACHE_DIR=str(evidence / 'old-shim-cache'))
run('old-monitor-build', ['nix', 'develop', '--command', 'bash',
    str(old / 'scripts/build_shim.sh')], cwd=monitor, env=old_env)
for mode in ['native', 'bootstrap', 'old', 'current']:
    for round_number in range(1, 4):
        name = f'{mode}-{round_number}'
        command = [str(binary)]
        environment = ['env', '-u', 'LD_PRELOAD', '-u', 'REPRO_MONITOR_SESSION',
                       '-u', 'REPRO_MONITOR_SHIM_LIB']
        if mode == 'bootstrap':
            command = ['repro', 'internal', 'io', 'monitor', '--depfile',
                       str(evidence / (name + '.iomon')), '--', *command]
        elif mode != 'native':
            shim = (evidence / 'old-shim/librepro_monitor_shim.so' if mode == 'old'
                    else monitor / 'build/lib/librepro_monitor_shim.so')
            environment.append('REPRO_MONITOR_SHIM_LIB=' + str(shim))
            command = [str(monitor / 'build/bin/io-mon'), 'run', '--depfile',
                       str(evidence / (name + '.iomon')), '--', *command]
        run(name, ['dev-exec', *environment, 'timeout', '--kill-after=10', '540',
                   *command], required=False)
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
        results[-1]['sha256'] = digest
        (evidence / 'results.json').write_text(json.dumps(results, indent=2))
if any(item['exitCode'] for item in results):
    raise SystemExit('A real comparison failed; inspect retained evidence')
