"""Compare real SQLite tests before/after batching, with unchanged deadlines.

No mocks. Both source variants use the same compiler, real SQLite, original
monitor shim and unchanged tests on one worker. Compilation runs natively;
ordinary product CI separately exercises monitored compilation.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def main():
    evidence = Path('build/merge-batching').resolve()
    names = ('t_observation_store_merge', 't_observation_store_export',
             't_observation_store_users')
    variants = ('original', 'batched')
    binaries = {(variant, name): evidence / variant / (name + '.exe')
                for variant in variants for name in names}
    shim = Path('reprobuild/build/lib/librepro_monitor_shim.dll').resolve()
    inputs = [*binaries.values(), shim]

    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

    initial = hashes()
    (evidence / 'input-sha256.json').write_text(json.dumps(initial, indent=2))
    repro, bash = shutil.which('repro'), shutil.which('bash')
    if not repro or not bash:
        raise RuntimeError('Missing activated runtime environment')
    results = []
    for mode in ('native', 'monitored'):
        for variant in variants:
            if hashes() != initial:
                raise RuntimeError('A comparison input changed')
            folder = evidence / variant / mode
            folder.mkdir(exist_ok=True)

            def run(name):
                binary = binaries[variant, name]
                command = [bash, '-c', 'timeout --kill-after=10 600 "$1" </dev/null',
                           'merge-batching', str(binary).replace('\\', '/')]
                env = os.environ.copy()
                if mode == 'monitored':
                    env['REPRO_MONITOR_SHIM_LIB'] = str(shim)
                    command = [repro, 'internal', 'io', 'monitor', '--depfile',
                               str(folder / (name + '.iomon')), '--', *command]
                start = time.monotonic()
                expired = False
                with (folder / (name + '.log')).open('wb') as output:
                    child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                             stdout=output, stderr=subprocess.STDOUT,
                                             env=env)
                    try:
                        code = child.wait(timeout=1900)
                    except subprocess.TimeoutExpired:
                        expired = True
                        subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                                       stdout=output, stderr=subprocess.STDOUT, timeout=30)
                        code = child.wait(timeout=30)
                return dict(variant=variant, mode=mode, name=name, exitCode=code,
                            outerExpired=expired, elapsedSeconds=time.monotonic() - start)

            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                futures = [pool.submit(run, name) for name in names]
                for future in concurrent.futures.as_completed(futures):
                    result = future.result()
                    results.append(result)
                    print(json.dumps(result), flush=True)
                    (evidence / 'results.json').write_text(json.dumps(results, indent=2))
    if hashes() != initial:
        raise RuntimeError('A comparison input changed during execution')
    return int(any(r['exitCode'] or r['outerExpired'] for r in results))


if __name__ == '__main__':
    raise SystemExit(main())
