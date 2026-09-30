"""Compare real growth/fork capture and the retained RunQuota heap fixture."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd()
monitor = root / '.io-mon'
evidence = root / 'build/linux-producer-fix'
evidence.mkdir(parents=True, exist_ok=True)
fixture = root / 'build/test-bin/t_m5_process_exec_bench_contract'
digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
assert digest == 'e3948fe9a7824d78ecf84d1d354ece929b0532839169514f121a0aabf7ce7165'
fixture.chmod(0o755)
# The Linux mapping policy identifies its own DSO by this basename. Renaming
# it would patch the shim itself and fail before the fixture reaches main.
original = evidence / 'original'
original.mkdir(exist_ok=True)
old_shim = original / 'librepro_monitor_shim.so'
shutil.copy2(monitor / 'build/lib/librepro_monitor_shim.so', old_shim)
old_cli = original / 'io-mon'
shutil.copy2(monitor / 'build/bin/io-mon', old_cli)
old_cli.chmod(0o755)
results = []


def run(name, args, *, cwd=root, env=None, required=False, bound=600):
    with (evidence / (name + '.log')).open('w') as output:
        try:
            code = subprocess.run(args, cwd=cwd, env=env, stdout=output,
                                  stderr=subprocess.STDOUT, timeout=bound).returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({'name': name, 'exitCode': code, 'fixtureSha256': digest})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == digest
    if required and code:
        raise SystemExit(name + ' failed; retained complete evidence')
    return code


store_paths = set()
for executable in (fixture, old_cli, old_shim):
    elf = subprocess.check_output(['readelf', '-l', '-d', str(executable)], text=True)
    store_paths.update(re.findall(r'/nix/store/[a-z0-9]{32}-[^/\s:]+', elf))
run('restore-runtime', ['nix', 'copy', '--from', 'https://cache.nixos.org',
                        *sorted(store_paths)], required=True)
run('apps-build', ['bash', 'scripts/build_apps.sh'], required=True)
run('production-build', ['nix', 'develop', '--command', 'just', 'build'],
    cwd=monitor, required=True)
regression = monitor / 'build/test-bin/test_io_mon_shared_producer_growth'
run('regression-build', ['nix', 'develop', '--command', 'nim', 'c', '--hints:off',
    '--threads:on', '-o:' + str(regression),
    'tests/linux/test_io_mon_shared_producer_growth.nim'], cwd=monitor, required=True)

clean = {key: value for key, value in os.environ.items()
         if not key.startswith('REPRO_MONITOR_') and key != 'LD_PRELOAD'}
variants = {'original': old_shim, 'production': monitor / 'build/lib/librepro_monitor_shim.so'}
for name, shim in variants.items():
    env = dict(clean, REPRO_MONITOR_SHIM_LIB=str(shim))
    run('growth-' + name, ['nix', 'develop', '--command', str(regression)],
        cwd=monitor, env=env, required=(name == 'production'))
for repetition in range(1, 9):
    for name, shim in variants.items():
        env = dict(clean, REPRO_MONITOR_SHIM_LIB=str(shim))
        label = f'fixture-{name}-{repetition}'
        run(label, [str(old_cli), 'run', '--depfile',
                   str(evidence / (label + '.iomon')), '--', str(fixture)],
            env=env, required=(name == 'production'))
heap_failures = []
for row in results:
    if not row['name'].startswith('fixture-original-'):
        continue
    output = (evidence / (row['name'] + '.log')).read_text(errors='replace')
    if (row['exitCode'] == 134 and output.count('[OK]') >= 10
            and re.search(r'double free|invalid pointer|corruption|invalid next size', output)):
        heap_failures.append(row['name'])
assert heap_failures, 'Original heap failure did not reproduce after entering the fixture'
print('Confirmed original heap failures:', ', '.join(heap_failures), flush=True)
