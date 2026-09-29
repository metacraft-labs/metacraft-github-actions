"""Compare shim runtime settings against the retained real failing binary."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = root / 'build/linux-heap-backtrace'
evidence.mkdir(parents=True, exist_ok=True)
binary = root / 'build/test-bin/t_m5_process_exec_bench_contract'
monitor = root / '.io-mon'
cli = monitor / 'build/bin/io-mon'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
assert digest == 'e3948fe9a7824d78ecf84d1d354ece929b0532839169514f121a0aabf7ce7165'
for path in (binary, cli):
    path.chmod(0o755)
results = []


def run(name, args, *, cwd=root, env=None, required=False, bound=480):
    with (evidence / (name + '.log')).open('w') as out:
        try:
            process = subprocess.run(args, cwd=cwd, env=env, stdout=out,
                                     stderr=subprocess.STDOUT, timeout=bound)
            code = process.returncode
        except subprocess.TimeoutExpired:
            code = 124
    results.append({'name': name, 'exitCode': code, 'fixtureSha256': digest})
    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    print(name, code, flush=True)
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    if required and code:
        raise SystemExit(name + ' failed; complete output retained')
    return code


run('apps-build', ['bash', 'scripts/build_apps.sh'], required=True)
variants = {'original': monitor / 'build/lib/librepro_monitor_shim.so'}
for name, flags in [('arc', ['--mm:arc']),
                    ('policy', ['--mm:arc', '--stackTrace:off', '--lineTrace:off',
                                '-d:noSignalHandler'])]:
    output = evidence / name
    environment = dict(os.environ, IO_MON_SHIM_OUT_DIR=str(output),
                       IO_MON_SHIM_NIMCACHE_DIR=str(evidence / (name + '-cache')))
    run(name + '-build', ['nix', 'develop', '--command', 'bash',
        'scripts/build_shim.sh', *flags], cwd=monitor, env=environment, required=True)
    variants[name] = output / 'librepro_monitor_shim.so'

for mode in ['native', *variants]:
    for repetition in range(1, 4):
        name = f'{mode}-{repetition}'
        environment = dict(os.environ)
        for key in list(environment):
            if key.startswith('REPRO_MONITOR_') or key == 'LD_PRELOAD':
                del environment[key]
        command = [str(binary)]
        if mode != 'native':
            environment['REPRO_MONITOR_SHIM_LIB'] = str(variants[mode])
            command = [str(cli), 'run', '--depfile',
                       str(evidence / (name + '.iomon')), '--', *command]
        run(name, ['timeout', '--kill-after=10', '420', *command], env=environment)

# GDB stays outside the injected process. Only its inferior receives the shim
# environment; SIGTRAP is passed through to the real syscall-hook handler.
gdb = shutil.which('gdb')
assert gdb, 'The workflow must provision GDB before collecting a stack'
run('gdb-version', [gdb, '--version'], required=True)
for repetition in range(1, 4):
    name = f'gdb-original-{repetition}'
    fragments = evidence / (name + '-fragments')
    fragments.mkdir()
    commands = ['set pagination off', 'set confirm off',
                'set follow-fork-mode parent', 'set detach-on-fork on',
                'handle SIGTRAP nostop noprint pass',
                'set environment LD_PRELOAD=' + str(variants['original']),
                'set environment REPRO_MONITOR_SHIM_LIB=' + str(variants['original']),
                'set environment REPRO_MONITOR_SESSION=' + name,
                'set environment REPRO_MONITOR_FRAGMENT_DIR=' + str(fragments),
                'set environment REPRO_MONITOR_OUTPUT=' + str(evidence / (name + '.iomon')),
                'set environment REPRO_MONITOR_DEP_SHM_DISABLE=1',
                'run', 'thread apply all bt full', 'info sharedlibrary']
    args = [gdb, '--batch']
    for command in commands:
        args.extend(['-ex', command])
    run(name, [*args, '--args', str(binary)])
    if 'SIGABRT' in (evidence / (name + '.log')).read_text(errors='replace'):
        break

if any(row['exitCode'] for row in results):
    raise SystemExit('At least one comparison failed; inspect retained evidence')
