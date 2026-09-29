#!/usr/bin/env python3
"""Exercise real private shim layouts, including the measured relink failure.

No monitoring or compiler mocks. The control truncates the shared ELF file
between fixture compilation and reader launch to reproduce a linker's observed
partial-file window. The actual compiler, shim, readers and assertions execute.
The old test must fail; the new one must still discover its private real shim.
"""
import concurrent.futures
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
out = root / 'build/diagnostics/private-linux-fixtures'
out.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
# These native controls do not inherit an enclosing monitoring session.
assert not env.get('LD_PRELOAD')
assert not env.get('REPRO_MONITOR_SHIM_LIB')


def run(name, argv, child_env=env, success=True):
    with (out / (name + '.log')).open('w') as log:
        result = subprocess.run(argv, env=child_env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=600)
    text = (out / (name + '.log')).read_text(errors='replace')
    print(name, result.returncode, flush=True)
    if success:
        assert result.returncode == 0, text[-12000:]
    return result.returncode, text


def compile_test(name, source):
    binary = out / name
    run('compile-' + name, ['nim', 'c', '--threads:on',
        '--nimcache:' + str(out / ('cache-' + name)),
        '--out:' + str(binary), str(source)])
    return str(binary)


stems = ['test_io_mon_per_call_env_and_cwd',
         'test_io_mon_evidence_scope_shim_gate',
         'test_io_mon_library_load_closure',
         'test_io_mon_linux_fragment_fd_reuse']
binaries = {s: compile_test(s, root / 'tests/linux' / (s + '.nim')) for s in stems}
run('shipping-shim', ['bash', 'scripts/build_shim.sh'])
run('private-layout-normal', [binaries[stems[0]]])

# Keep source inside the actual tests tree so currentSourcePath and Nim's
# parent configuration resolve exactly as they do in the old fixture.
old_source = root / 'tests/linux/private_layout_before.nim'
old_source.write_bytes(subprocess.check_output(['git', 'show',
    '358a1880aab8ac4db9bd99fc50c7128adbe3fbdc:tests/linux/test_io_mon_per_call_env_and_cwd.nim']))
try:
    old_binary = compile_test('private-layout-before', old_source)
finally:
    old_source.unlink()
real_cc = shutil.which(env.get('CC', 'cc'))
assert real_cc
wrapper = out / 'controlled_cc'
wrapper.write_text('#!' + shutil.which('python3') + '\n' +
    'import subprocess, sys\nfrom pathlib import Path\n' +
    'result = subprocess.run([' + repr(real_cc) + '] + sys.argv[1:])\n' +
    'if result.returncode == 0 and any(a.endswith("dh1_relative_reader.c") for a in sys.argv[1:]):\n' +
    '    Path(' + repr(str(root / 'build/lib/librepro_monitor_shim.so')) + ').write_bytes(b"x")\n' +
    'sys.exit(result.returncode)\n')
wrapper.chmod(0o755)
controlled = {**env, 'CC': str(wrapper)}
run('private-layout-partial-shared-library', [binaries[stems[0]]], controlled)
code, log = run('shared-layout-negative', [old_binary], controlled, success=False)
assert code != 0 and 'file too short' in log and '[FAILED] t_parent_env_is_unchanged_after_a_monitored_run' in log, log[-12000:]
(root / 'build/lib/librepro_monitor_shim.so').unlink(missing_ok=True)
run('restore-shipping-shim', ['bash', 'scripts/build_shim.sh'])

# Also exercise actual simultaneous source builds and loads, without the
# truncation control. Private fixtures and the shipping relink all run live.
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    futures = [pool.submit(run, 'concurrent-' + s, [binaries[s]]) for s in stems]
    futures.append(pool.submit(run, 'concurrent-shipping-relink', ['bash', 'scripts/build_shim.sh']))
    for future in futures:
        future.result()
print('Private fixtures pass normal, partial-file, and concurrent-build controls; the old layout fails.', flush=True)
