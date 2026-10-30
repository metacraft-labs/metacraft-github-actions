"""Run the action's generated wrappers against a real qualified Repro CLI.

No CLI, process, filesystem or environment adapter is mocked in the SDK
activation/cwd/status controls. A tiny real recipe identifies its environment;
a native Python child reports only its cwd, relative input and exact arguments.
The installer is extracted by the
existing native-status fixture. Windows wrappers run only on Windows, and
Linux results never qualify their native execution. No SDK is built here.
The separately justified CLI argument-recorder controls are run afterwards;
they test provisioning-argument dispatch, not SDK realization.
"""
import argparse
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('native_status_fixture',
                                              HERE / 'test-windows-cmd-status.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def write_fixture(path, text):
    # The actual installer contains Unicode comments, and its Bash body must
    # retain LF even when this fixture is driven by native Windows Python.
    path.write_text(text, encoding='utf-8', newline='\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repro', type=Path, required=True)
    parser.add_argument('--action-yml', type=Path, default=HERE / 'action.yml')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--expect-old-cwd-bug', action='store_true')
    args = parser.parse_args()
    repro = args.repro.resolve(strict=True)
    bash = shutil.which('bash')
    if not repro.is_file() or not os.access(repro, os.X_OK) or not bash:
        parser.error('a real executable Repro CLI and Bash are required')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    streams = args.report.with_suffix('.streams')
    streams.mkdir()
    commands = []

    def run(argv, cwd, env, timeout=600):
        # Files retain diagnostics without waiting for EOF from a daemon that
        # inherited stdout. subprocess owns and waits for its own client only.
        stem = streams / str(len(commands))
        out, err = stem.with_suffix('.stdout'), stem.with_suffix('.stderr')
        with out.open('xb') as stdout, err.open('xb') as stderr:
            result = subprocess.run(argv, cwd=cwd, env=env, stdout=stdout,
                                    stderr=stderr, timeout=timeout)
        commands.append({'argv': [str(x) for x in argv], 'cwd': str(cwd),
                          'exit': result.returncode, 'stdout': str(out), 'stderr': str(err)})
        return (result.returncode, out.read_bytes().decode('utf-8', errors='replace'),
                err.read_bytes().decode('utf-8', errors='replace'))

    rows = []
    try:
        with tempfile.TemporaryDirectory(prefix='shared-dev-exec-cwd-') as temporary, ExitStack() as cleanup:
            root = Path(temporary)
            consumer = root / 'setup project'
            nested = consumer / 'src' / 'nested directory'
            nested.mkdir(parents=True)
            write_fixture(consumer / 'repro.nim',
                'import repro_project_dsl\npackage wrapperFixture:\n'
                '  devEnv:\n    setEnv "GHA_CWD_FIXTURE", "setup-project"\n')
            write_fixture(consumer / 'input.txt', 'root input')
            write_fixture(nested / 'input.txt', 'nested input')
            child = root / 'report child.py'
            write_fixture(child,
                'import json,os,sys\nfrom pathlib import Path\n'
                'print(json.dumps({"cwd":str(Path.cwd()),'
                '"environment":os.environ.get("GHA_CWD_FIXTURE"),'
                '"input":Path("input.txt").read_text(encoding="utf-8"),"args":sys.argv[1:]}))\n'
                'sys.exit(int(sys.argv[-1]))\n')
            home = root / 'private home'
            home.mkdir()
            env = dict(os.environ, PATH=str(repro.parent) + os.pathsep + os.environ['PATH'])
            env['GHA_CWD_FIXTURE'] = 'wrong-ambient-value'
            if os.name == 'nt':
                # The existing native status fixture requires a clean real Git
                # consumer and immutable environment inputs. Keep its guards.
                template = root / 'empty git template'
                hooks = root / 'empty git hooks'
                template.mkdir()
                hooks.mkdir()
                write_fixture(consumer / '.gitignore', '.repro/\n')
                git = shutil.which('git')
                if not git:
                    raise RuntimeError('real Git is required by the native status fixture')
                for tail in [
                        ['init', '--template=' + str(template)],
                        ['config', 'core.hooksPath', str(hooks)],
                        ['config', 'core.fsmonitor', 'false'],
                        ['add', '.'],
                        ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                          '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture environment']]:
                    code, output, error = run([git, '-C', str(consumer), *tail], consumer, env)
                    if code:
                        raise RuntimeError('native consumer fixture preparation failed:\n' + output + error)
                # Reuse the native fixture's private-pipe identity check. Never
                # adopt or terminate a runner daemon, or leave an owned daemon
                # holding the temporary consumer's directory during cleanup.
                daemon_exe = repro.with_name('runquotad.exe')
                quota_exe = repro.with_name('runquota.exe')
                if not daemon_exe.is_file() or not quota_exe.is_file():
                    raise RuntimeError('the real SDK RunQuota companions are required')
                endpoint = r'\\.\pipe\gha-cwd-' + uuid.uuid4().hex
                env['RUNQUOTA_SOCKET'] = endpoint
                daemon_out = cleanup.enter_context((streams / 'daemon.stdout').open('xb'))
                daemon_err = cleanup.enter_context((streams / 'daemon.stderr').open('xb'))
                daemon = subprocess.Popen([str(daemon_exe), '--socket', endpoint],
                    cwd=root, env=env, stdout=daemon_out, stderr=daemon_err)

                def settle_owned_daemon():
                    if daemon.poll() is None:
                        daemon.terminate()  # Popen retains this exact native HANDLE.
                    daemon.wait(timeout=10)

                cleanup.callback(settle_owned_daemon)
                deadline = time.monotonic() + 20
                while True:
                    if daemon.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('owned private RunQuota did not become ready')
                    code, output, error = run([str(quota_exe), 'status', '--json'], root, env,
                                              timeout=deadline - time.monotonic())
                    if code == 0:
                        fixture.daemon_identity(daemon, endpoint)
                        break
                    time.sleep(0.2)
            # First prove real provider activation succeeds. An unrelated
            # compiler/SDK error cannot count as the intended old failure.
            code, output, error = run([str(repro), 'exec', str(consumer), '--',
                                        sys.executable, str(child), '0'], consumer, env)
            if code or json.loads(output.strip().splitlines()[-1])['environment'] != 'setup-project':
                raise RuntimeError('actual CLI activation baseline failed:\n' + output + error)
            install_env = dict(env, HOME=str(home), USERPROFILE=str(home),
                                RUNNER_OS='Windows' if os.name == 'nt' else 'Linux',
                                RUNNER_TEMP=str(root / 'runner temp'),
                                GITHUB_ENV=str(root / 'github-env'),
                                GITHUB_PATH=str(root / 'github-path'),
                                MCL_CONSUMER_ROOT=str(consumer))
            (root / 'runner temp').mkdir()
            for name in ('github-env', 'github-path'):
                (root / name).touch()
            installer = root / 'install-wrapper.sh'
            write_fixture(installer, fixture.installer_body(args.action_yml.resolve()))
            code, output, error = run([bash, str(installer)], consumer, install_env)
            if code:
                raise RuntimeError('actual installer failed:\n' + output + error)
            first_directory = fixture.installed_wrapper_directory(root / 'github-path')
            # A second setup shares both HOME and RUNNER_TEMP. Its project
            # binding must not redirect the first installation's commands.
            second = root / 'second setup project'
            second_nested = second / 'src' / 'nested directory'
            second_nested.mkdir(parents=True)
            write_fixture(second / 'repro.nim',
                (consumer / 'repro.nim').read_text(encoding='utf-8').replace('setup-project', 'second-project'))
            write_fixture(second_nested / 'input.txt', 'second nested input')
            code, output, error = run([bash, str(installer)], second,
                                      dict(install_env, MCL_CONSUMER_ROOT=str(second)))
            if code:
                raise RuntimeError('second actual installer failed:\n' + output + error)
            second_directory = fixture.installed_wrapper_directory(root / 'github-path')
            if not args.expect_old_cwd_bug and first_directory == second_directory:
                raise RuntimeError('two setups replaced the same wrapper installation')
            native_tools = {}
            if os.name == 'nt':
                pwsh, cmd = shutil.which('pwsh'), shutil.which('cmd.exe')
                if not pwsh or not cmd:
                    raise RuntimeError('real PowerShell and CMD are required on Windows')
                native_tools = {'pwsh': pwsh, 'cmd': cmd}
            for installation, directory, working_directory, marker, input_text in [
                    ('first', first_directory, nested, 'setup-project', 'nested input'),
                    ('second', second_directory, second_nested, 'second-project', 'second nested input')]:
                wrapper = directory / 'dev-exec'
                wrappers = [('bash', [bash, str(wrapper)])]
                if native_tools:
                    wrappers.extend([
                        ('pwsh', [native_tools['pwsh'], '-NoProfile', '-File',
                                  str(wrapper.with_suffix('.ps1'))]),
                        ('cmd', [])])
                for name, prefix in wrappers:
                    for status in (0, 19):
                        tail = [sys.executable, str(child), '', 'space argument', str(status)]
                        argv = (fixture.write_cmd_driver(
                            root / f'case-{installation}-{status}.cmd', wrapper.with_suffix('.cmd'),
                            tail, native_tools['cmd']) if name == 'cmd' else prefix + tail)
                        code, output, error = run(argv, working_directory, env)
                        intended_old = code != 0 and 'dev-env target module not found:' in error
                        if args.expect_old_cwd_bug:
                            if not intended_old:
                                raise RuntimeError('old wrapper did not fail at nested recipe selection:\n' + output + error)
                            rows.append({'installation': installation, 'wrapper': name,
                                          'status': status, 'intendedOldFailure': True})
                            continue
                        if code != status:
                            raise RuntimeError('wrong child status:\n' + output + error)
                        observed = json.loads(output.strip().splitlines()[-1])
                        expected = {'cwd': str(working_directory), 'environment': marker,
                                    'input': input_text, 'args': ['', 'space argument', str(status)]}
                        # Windows may expand a temporary directory's 8.3 name.
                        # Require the same physical directory, not its spelling.
                        same_directory = Path(observed['cwd']).samefile(working_directory)
                        if not same_directory or any(
                                observed[key] != expected[key] for key in ('environment', 'input', 'args')):
                            raise RuntimeError('cwd/environment/argv/relative input changed: '
                                                + repr({'expected': expected, 'observed': observed}))
                        rows.append({'installation': installation, 'wrapper': name,
                                      'status': status, 'expected': expected, 'observed': observed,
                                      'sameDirectory': same_directory})
            if not args.expect_old_cwd_bug:
                code, output, error = run([
                    sys.executable, str(HERE / 'test-repro-exec.py'),
                    'ProvisioningArguments'], consumer,
                    dict(env, GHA_TEST_ACTION_YML=str(args.action_yml.resolve())))
                if code:
                    raise RuntimeError('generated provisioning argument controls failed:\n' +
                                        output + error)
            if os.name == 'nt' and not args.expect_old_cwd_bug:
                # Run every existing special-dispatch and generic status case,
                # not a new approximation of their CMD invocation boundary.
                code, output, error = run([
                    sys.executable, str(HERE / 'test-windows-cmd-status.py'),
                    '--action-yml', str(args.action_yml.resolve()), '--repro', str(repro),
                    '--runquotad', str(repro.with_name('runquotad.exe')),
                    '--runquota', str(repro.with_name('runquota.exe')),
                    '--consumer', str(consumer), '--profile-input', str(consumer / 'repro.nim'),
                    '--report', str(args.report.with_name('native-status-result.json'))], consumer, env)
                if code:
                    raise RuntimeError('existing whole native status controls failed:\n' + output + error)
    finally:
        write_fixture(args.report, json.dumps({'repro': str(repro),
            'action': str(args.action_yml.resolve()), 'platform': sys.platform,
            'expectOldFailure': args.expect_old_cwd_bug, 'cases': rows,
            'commands': commands, 'nativeWindows': os.name == 'nt'}, indent=2) + '\n')
    print(json.dumps({'cases': len(rows), 'nativeWindows': os.name == 'nt',
                      'expectedOldFailure': args.expect_old_cwd_bug}))


if __name__ == '__main__':
    main()
