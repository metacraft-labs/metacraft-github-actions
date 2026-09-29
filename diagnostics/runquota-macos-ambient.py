"""Compare unchanged real fixtures; extra window output is after measurement."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = root / 'build/macos-ambient-evidence'
evidence.mkdir(parents=True, exist_ok=True)
results = []

def run(name, args, cwd=root, env=None, required=True):
    with (evidence / (name + '.log')).open('w') as out:
        child = subprocess.run(args, cwd=cwd, env=env, stdout=out,
                               stderr=subprocess.STDOUT, timeout=1200)
    results.append({'name': name, 'exitCode': child.returncode})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, child.returncode, flush=True)
    if required and child.returncode:
        raise SystemExit(name + ' failed')

source = (root / 'tests/integration/t_ambient_load_attribution.nim').read_text()
anchor = '    let pairedRatio =\n'
assert source.count(anchor) == 1
source = source.replace(anchor, '''    for i in 0 ..< cpuCycles:
      echo "  diagnostic cycle=", i,
        " offCpu=", foreignCpu(inWindows(rows, [offWindows[i]])),
        " onCpu=", foreignCpu(inWindows(rows, [onWindows[i]])),
        " ownOff=", ownCpuPct([offWindows[i]]),
        " ownOn=", ownCpuPct([onWindows[i]]),
        " offFrom=", offWindows[i].fromMillis,
        " offTo=", offWindows[i].toMillis,
        " onFrom=", onWindows[i].fromMillis,
        " onTo=", onWindows[i].toMillis
    let pairedRatio =
''')
diagnostic = root / 'build/diagnostics/t_ambient_window_diagnostic.nim'
diagnostic.parent.mkdir(parents=True, exist_ok=True)
diagnostic.write_text(source)
run('apps', ['nix', 'develop', '--command', 'bash', 'scripts/build_apps.sh'])
programs = [diagnostic, root / 'libs/runquota_host_macos/tests/t_runquota_host_macos_native_process_telemetry.nim']
for src in programs:
    assert src.exists(), src
    run(src.stem + '-compile', ['nix', 'develop', '--command', 'nim', 'c',
        '--hints:off', '--cc:clang', '--threads:on',
        '--out:' + str(evidence / src.stem), str(src)])

monitor = root / '.io-mon'
run('current-monitor-build', ['nix', 'develop', '--command', 'just', 'build'], cwd=monitor)
old = root / 'build/old-monitor'
old.mkdir(parents=True, exist_ok=True)
archive = subprocess.check_output(['git', 'archive', '4b2bb3910283bac4d109012411e42ce67f9c969c'], cwd=monitor)
subprocess.run(['tar', '-xf', '-', '-C', str(old)], input=archive, check=True)
old_env = dict(os.environ, IO_MON_SHIM_OUT_DIR=str(evidence / 'old-shim'),
               IO_MON_SHIM_NIMCACHE_DIR=str(evidence / 'old-shim-cache'))
# The current flake supplies the same source dependencies to both compilations.
run('old-monitor-build', ['nix', 'develop', '--command', 'bash',
    str(old / 'scripts/build_shim.sh')], cwd=monitor, env=old_env)
for mode in ['native', 'current', 'old']:
    env = dict(os.environ)
    env['REPRO_MONITOR_SHIM_LIB'] = str(
        evidence / 'old-shim/librepro_monitor_shim.dylib' if mode == 'old'
        else monitor / 'build/lib/librepro_monitor_shim.dylib')
    for src in programs:
        binary = evidence / src.stem
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        name = src.stem + '-' + mode
        command = [str(binary)]
        if mode != 'native':
            command = [str(monitor / 'build/bin/io-mon'), 'run', '--depfile',
                       str(evidence / (name + '.iomon')), '--', *command]
        run(name, ['nix', 'develop', '--command', *command], env=env, required=False)
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
        results[-1]['sha256'] = digest
(evidence / 'results.json').write_text(json.dumps(results, indent=2))
if any(x['exitCode'] for x in results):
    raise SystemExit(1)
