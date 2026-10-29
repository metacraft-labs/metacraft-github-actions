"""Exercise the generated CMD trampoline with real installed Repro and PowerShell.

This is a native Windows status-boundary regression, not a build/test-suite or
bootstrap acceptance test. No executable is mocked. The action's actual wrapper
installation step produces both wrappers in a private home. Build/test help and
invalid variant syntax stop at the real CLI parser; generic exec needs an already
qualified consumer environment supplied by the caller. Its normal provider/tool
prerequisites must be priced before execution. Non-Windows execution fails loudly.

CMD expands percent variables when it reads a compound statement, before running
its child: https://devblogs.microsoft.com/oldnewthing/20060823-00/?p=29993
An ERRORLEVEL environment variable can shadow the internal status, so the fixture
removes that override: https://devblogs.microsoft.com/oldnewthing/20080926-00/?p=20743
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

STEP = 'Install dev-exec wrapper (reprobuild)'
INVALID = '--variant expects name=value (got: invalid)'


class Capture:
    """Keep this invocation's command mapping and raw streams on failure too."""

    def __init__(self, directory):
        self.directory = directory
        self.directory.mkdir(mode=0o700)
        self.commands = []

    def persist(self):
        (self.directory / 'commands.json').write_text(
            json.dumps(self.commands, indent=2), encoding='utf-8')

    def run(self, argv, cwd, env, timeout=120):
        # A daemon holding inherited stdout must not turn a bounded parent wait
        # into an unbounded pipe-EOF wait. Keep the complete raw files.
        stem = self.directory / ('command-' + str(len(self.commands)))
        out_path, err_path = stem.with_suffix('.stdout'), stem.with_suffix('.stderr')
        entry = {'argv': argv, 'cwd': str(cwd), 'timeoutSeconds': timeout,
                  'stdout': str(out_path), 'stderr': str(err_path)}
        self.commands.append(entry)
        self.persist()
        child = None
        try:
            with out_path.open('xb') as out, err_path.open('xb') as err:
                child = subprocess.Popen(argv, cwd=cwd, env=env, stdout=out, stderr=err)
                entry['pid'] = child.pid
                self.persist()
                try:
                    code = child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    # A live parent HANDLE prevents PID reuse. Kill only its
                    # owned tree; the separately owned daemon has its own handle.
                    if child.poll() is None:
                        subprocess.run(['taskkill.exe', '/PID', str(child.pid), '/T', '/F'],
                                        stdout=out, stderr=err, timeout=10, check=True)
                    child.wait(timeout=10)
                    raise
            return subprocess.CompletedProcess(argv, code,
                out_path.read_bytes().decode('utf-8', errors='replace'),
                err_path.read_bytes().decode('utf-8', errors='replace'))
        except BaseException as error:
            entry['error'] = repr(error)
            raise
        finally:
            entry['exit'] = child.poll() if child is not None else None
            self.persist()


def daemon_identity(child, endpoint):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    times = [wintypes.FILETIME() for _ in range(4)]
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    if not kernel.GetProcessTimes(child._handle, *[ctypes.byref(t) for t in times]):
        raise ctypes.WinError(ctypes.get_last_error())
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                  wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    pipe = kernel.CreateFileW(endpoint, 0xC0000000, 0, None, 3, 0, None)
    if pipe == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        server = wintypes.ULONG()
        kernel.GetNamedPipeServerProcessId.argtypes = [wintypes.HANDLE,
                                                        ctypes.POINTER(wintypes.ULONG)]
        if not kernel.GetNamedPipeServerProcessId(pipe, ctypes.byref(server)):
            raise ctypes.WinError(ctypes.get_last_error())
        if server.value != child.pid:
            raise RuntimeError('private pipe is not served by the owned daemon')
    finally:
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle(pipe)
    return {'serverPID': server.value,
            'creationFILETIME': (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime}


def fingerprint(paths):
    result = {}
    for path in paths:
        path = path.resolve(strict=True)
        files = sorted(path.rglob('*')) if path.is_dir() else [path]
        result[str(path)] = [(str(p.relative_to(path) if path.is_dir() else p.name),
                              hashlib.sha256(p.read_bytes()).hexdigest())
                            for p in files if p.is_file()]
    return result


def consumer_state(capture, consumer, profiles, env):
    def git(*args):
        value = capture.run(['git', '-C', str(consumer), *args], consumer,
                    dict(env, GIT_OPTIONAL_LOCKS='0'))
        if value.returncode != 0:
            raise RuntimeError('consumer identity probe failed: ' + value.stderr)
        return value.stdout
    status = git('status', '--porcelain=v1')
    if status:
        raise RuntimeError('qualified consumer must remain clean: ' + status)
    config = env.get('REPRO_WORKSPACE_CONFIG')
    config_path = Path(config) if config else None
    if config_path is not None and not config_path.is_absolute():
        config_path = consumer / config_path
    config_files = [config_path] if config_path is not None else []
    return {'head': git('rev-parse', 'HEAD').strip(),
            'index': git('ls-files', '--stage'),
            'sourceDiff': git('diff', '--binary', 'HEAD'),
            'trackedFiles': fingerprint([consumer / p for p in
                                          git('ls-files').splitlines()]),
            'profiles': fingerprint(profiles),
            'workspaceConfig': {'value': config,
                                'resolved': str(config_path.resolve()) if config_path else None,
                                'files': fingerprint(config_files)}}


def installer_body(action):
    step = action.read_text(encoding='utf-8').split('    - name: ' + STEP + '\n', 1)[1]
    step = step.split('    - name: ', 1)[0]
    body = step.split('      run: |\n', 1)[1]
    return '\n'.join(line[8:] if line.startswith('        ') else line
                      for line in body.splitlines()) + '\n'


def installed_wrapper_directory(github_path):
    """Use the actual installer handoff, including older installation layouts."""
    for value in reversed(github_path.read_text(encoding='utf-8').splitlines()):
        candidate = Path(value)
        if (candidate / 'dev-exec').is_file() or (candidate / 'dev-exec.cmd').is_file():
            return candidate
    raise RuntimeError('the installer published no actual dev-exec directory')


def write_cmd_driver(path, wrapper, argv, cmd, prior=0):
    """Keep CALL and the final status on separately parsed CMD lines."""
    command = subprocess.list2cmdline([str(wrapper), *argv])
    path.write_text('@echo off\n' +
                    '"' + cmd + '" /d /c exit /b ' + str(prior) + '\n' +
                    'call ' + command + '\n' +
                    'exit /b %ERRORLEVEL%\n', encoding='utf-8', newline='\n')
    return [cmd, '/d', '/v:off', '/c', str(path)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--action-yml', type=Path,
                        default=Path(__file__).with_name('action.yml'))
    parser.add_argument('--repro', type=Path, required=True)
    parser.add_argument('--runquotad', type=Path, required=True)
    parser.add_argument('--runquota', type=Path, required=True)
    parser.add_argument('--profile-input', type=Path, action='append', required=True,
                        help='actual qualified immutable provider/environment inputs')
    parser.add_argument('--consumer', type=Path, required=True,
                        help='existing qualified consumer; no provisioning here')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--expect-old-status-bug', action='store_true',
                        help='require exactly the four old special-branch mismatches')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('native Windows CMD/PowerShell execution is required')
    repro = args.repro.resolve(strict=True)
    consumer = args.consumer.resolve(strict=True)
    if repro.name.lower() != 'repro.exe' or not consumer.is_dir():
        parser.error('real installed repro.exe and existing consumer are required')
    tools = {name: shutil.which(name) for name in ('bash', 'pwsh', 'cmd.exe', 'cygpath')}
    if not all(tools.values()):
        parser.error('real Git Bash, PowerShell, CMD and cygpath must be installed')
    env = dict(os.environ)
    # Windows environment names are case insensitive. Avoid a shadow status.
    for key in list(env):
        if key.upper() == 'ERRORLEVEL':
            del env[key]
    if env.get('REPROBUILD_NO_RUNQUOTA', '').lower() in ('1', 'true', 'yes', 'on'):
        parser.error('RunQuota bypass is not a native fixture prerequisite')
    env['PATH'] = str(repro.parent) + os.pathsep + env.get('PATH', '')
    resolved = shutil.which('repro', path=env['PATH'])
    if resolved is None or Path(resolved).resolve() != repro:
        parser.error('the selected installed Repro must win normal PATH lookup')
    capture = Capture(args.report.resolve().with_suffix('.streams'))
    rows = []
    runtime_env = dict(env)
    before = consumer_state(capture, consumer, args.profile_input, runtime_env)
    sdk_paths = [repro, repro.with_name('reprobuild.exe'),
                  args.runquota, args.runquotad,
                  *[Path(value) for value in tools.values()]]
    sdk_before = fingerprint(sdk_paths)
    daemon = None
    daemon_receipt = None
    with tempfile.TemporaryDirectory(prefix='native-cmd-status-') as tmp:
        home = Path(tmp)
        install_env = dict(env)
        install_env.update(HOME=str(home), USERPROFILE=str(home), RUNNER_OS='Windows',
                    GITHUB_ENV=str(home / 'github-env'),
                    GITHUB_PATH=str(home / 'github-path'),
                    RUNNER_TEMP=str(home / 'runner-temp'),
                    MCL_CONSUMER_ROOT=str(consumer))
        (home / 'runner-temp').mkdir()
        (home / 'github-env').touch()
        (home / 'github-path').touch()
        script = home / 'install-wrapper.sh'
        script.write_text(installer_body(args.action_yml.resolve(strict=True)),
                          encoding='utf-8', newline='\n')
        installed = capture.run([tools['bash'], str(script)], consumer, install_env)
        if installed.returncode != 0:
            raise RuntimeError('actual wrapper installation failed:\n' +
                                installed.stdout + installed.stderr)
        wrapper = installed_wrapper_directory(home / 'github-path') / 'dev-exec.cmd'
        if not wrapper.is_file() or not wrapper.with_suffix('.ps1').is_file():
            raise RuntimeError('the actual installer did not generate both wrappers')
        # A unique explicit named pipe prevents adopting/stopping a host daemon.
        # Repro's supplied-endpoint reachability arm precedes its default spawn.
        endpoint = r"\\.\pipe\gha-cmd-status-" + uuid.uuid4().hex
        runtime_env['RUNQUOTA_SOCKET'] = endpoint
        daemon_stdout = (capture.directory / 'owned-runquotad.stdout').open('xb')
        daemon_stderr = (capture.directory / 'owned-runquotad.stderr').open('xb')
        try:
            daemon = subprocess.Popen([str(args.runquotad.resolve(strict=True)),
                                        '--socket', endpoint], cwd=consumer,
                                      env=runtime_env, stdout=daemon_stdout,
                                      stderr=daemon_stderr)
            # Popen retains the exact process HANDLE, not a name-only PID lookup.
            daemon_receipt = {'pid': daemon.pid, 'endpoint': endpoint,
                              'image': str(args.runquotad.resolve()),
                              'imageSHA256': hashlib.sha256(args.runquotad.read_bytes()).hexdigest()}
            deadline = time.monotonic() + 20
            while True:
                if daemon.poll() is not None:
                    raise RuntimeError('own RunQuota daemon exited before readiness')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('own RunQuota endpoint did not become ready')
                ready = capture.run([str(args.runquota.resolve(strict=True)), 'status', '--json'],
                                    consumer, runtime_env, timeout=remaining)
                if ready.returncode == 0:
                    daemon_receipt['status'] = ready.stdout
                    daemon_receipt.update(daemon_identity(daemon, endpoint))
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('own RunQuota endpoint did not become ready')
                time.sleep(0.2)
            for verb in ('build', 'test'):
                for success in (True, False):
                    # The exact same explicit flags reach direct and wrapped Repro.
                    tail = ['--help'] if success else ['--variant=invalid']
                    cli = [verb, *tail, '--tool-provisioning=path', '--daemon=off']
                    direct = capture.run([str(repro), *cli], consumer, runtime_env)
                    text = direct.stdout + direct.stderr
                    if success:
                        if direct.returncode != 0 or 'usage' not in text.lower():
                            raise RuntimeError('real ' + verb + ' help baseline failed: ' + text)
                    elif direct.returncode == 0 or INVALID not in text:
                        raise RuntimeError('real ' + verb + ' variant baseline failed: ' + text)
                    rows.append(check_case(capture, verb + ('-success' if success else '-failure'),
                                            ['repro', *cli], 23 if success else 0,
                                            direct, wrapper, tools, consumer, runtime_env))
            for status in (0, 19):
                marker = 'native-cmd-status-child-' + str(status)
                child = [tools['cmd.exe'], '/d', '/v:off', '/c',
                          'echo ' + marker + ' & exit /b ' + str(status)]
                direct = capture.run([str(repro), 'exec', '--', *child], consumer, runtime_env)
                if direct.returncode != status or marker not in direct.stdout:
                    raise RuntimeError('real generic exec baseline failed:\n' +
                                        direct.stdout + direct.stderr)
                rows.append(check_case(capture, 'generic-' + str(status), child,
                                        23 if status == 0 else 0, direct, wrapper,
                                        tools, consumer, runtime_env))
        finally:
            if daemon is not None:
                if daemon.poll() is None:
                    # Terminate only the exact fixture-created process handle.
                    daemon.terminate()
                daemon.wait(timeout=10)
                daemon_receipt['terminalExit'] = daemon.returncode
                daemon_receipt['ownedHandleWaited'] = True
                kernel = ctypes.WinDLL('kernel32', use_last_error=True)
                kernel.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
                if kernel.WaitNamedPipeW(endpoint, 0) or ctypes.get_last_error() != 2:
                    raise RuntimeError('owned private pipe did not disappear after daemon exit')
                daemon_receipt['privatePipeGone'] = True
            daemon_stdout.close()
            daemon_stderr.close()
            after = consumer_state(capture, consumer, args.profile_input, env)
            if fingerprint(sdk_paths) != sdk_before:
                raise RuntimeError('selected SDK or native tool bytes changed')
            if after != before:
                raise RuntimeError('consumer source/config/index/locks/profile changed')
    mismatches = [row['name'] for row in rows if not row['matched']]
    report = {'repro': str(repro), 'tools': tools, 'consumer': str(consumer),
              'action': str(args.action_yml.resolve()), 'cases': rows,
              'statusMismatches': mismatches, 'nativeWindows': True,
              'consumerBefore': before, 'consumerAfter': after,
              'ownedRunQuota': daemon_receipt, 'commands': capture.commands,
              'sdkAndNativeTools': sdk_before,
              'configurationScope': 'tracked consumer files, explicit REPRO_WORKSPACE_CONFIG, '
                                    'and supplied profile inputs only; other resolved config '
                                    'inputs require caller qualification and are otherwise UNKNOWN'}
    args.report.write_text(json.dumps(report, indent=2))
    expected = ['build-success', 'build-failure', 'test-success', 'test-failure']
    if args.expect_old_status_bug:
        if mismatches != expected or any(row['wrappedExit'] != row['priorStatus']
                                          for row in rows[:4]):
            raise RuntimeError('old implementation did not exhibit exactly the expected bug: ' +
                                repr(mismatches))
    elif mismatches:
        raise RuntimeError('wrapper lost real child statuses: ' + repr(mismatches))


def check_case(capture, name, argv, prior, direct, wrapper, tools, cwd, env):
    # CALL is needed to return from a .cmd child. Every line is parsed separately;
    # the fixture itself must not repeat the production compound-expansion bug.
    # Delayed expansion stays OFF so arguments containing ! retain their meaning.
    driver = wrapper.parent / ('case-' + name + '.cmd')
    invocation = write_cmd_driver(driver, wrapper, argv, tools['cmd.exe'], prior)
    wrapped = capture.run(invocation, cwd, env)
    # Diagnostic/output equality also rejects a wrong executable or parser path.
    if (not name.startswith('generic-') and
            (wrapped.stdout != direct.stdout or wrapped.stderr != direct.stderr)):
        raise RuntimeError(name + ': wrapped output differs from real direct command:\n' +
                            wrapped.stdout + wrapped.stderr)
    if name.startswith('generic-'):
        marker = 'native-cmd-status-child-' + name.split('-', 1)[1]
        if marker not in wrapped.stdout:
            raise RuntimeError(name + ': real generic child marker is absent')
    return {'name': name, 'priorStatus': prior,
            'directExit': direct.returncode, 'wrappedExit': wrapped.returncode,
            'matched': wrapped.returncode == direct.returncode,
            'stdout': wrapped.stdout, 'stderr': wrapped.stderr}


if __name__ == '__main__':
    main()
