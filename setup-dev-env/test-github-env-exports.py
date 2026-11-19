"""Check that setup-dev-env never exports a variable that changes how later
steps find or start programs.

Whatever the action appends to `$GITHUB_ENV` reaches every later step of the
job and, through `repro exec`, every process those steps start. A variable
that steers program lookup or loading therefore changes commands the action
never sees. The action once exported `PATHEXT=.PS1;...` so that pwsh would
pick `dev-exec.ps1`. pwsh did not need it, and cmd.exe obeyed it: under it,
`cmd /c napi` resolved an npm shim directory's `napi.ps1` instead of
`napi.cmd` and handed the script to the `.ps1` file association. Depending
on the host and account, the build then hung or exited 0 without napi having
run. PATH is listed too because it must go through
`$GITHUB_PATH`, which prepends, rather than replace the job's PATH.

Three checks, each against the action as written:

- every `$GITHUB_ENV` write in action.yml and in the scripts its steps run
  is read, and none may name a variable from FORBIDDEN. Writes whose variable
  name is computed at run time are listed in DYNAMIC_WRITERS with the reason
  they are allowed;
- the "Install dev-exec wrapper (reprobuild)" step really runs under bash,
  as a Windows job and as a Linux job, and the `$GITHUB_ENV` file it leaves
  must not set a FORBIDDEN variable;
- on Windows only, cmd.exe started with the job environment that step
  produces runs `napi.cmd`, not `napi.ps1`, from a directory holding both,
  the way npm installs a package's command shims.

One stand-in: off Windows, the step's `cygpath -w` calls are served by a
script that prints its path argument unchanged. Only the text of the path
reaches the files the step writes, and this check is about which variables it
exports, not about Windows path syntax. On Windows the real Git Bash and
cygpath are required.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ACTION = HERE / 'action.yml'
STEP = 'Install dev-exec wrapper (reprobuild)'
WINDOWS = os.name == 'nt'

# Variables that decide which program a name resolves to, how a shell starts,
# or which libraries a program loads. Compared case-insensitively, as Windows
# compares environment names.
FORBIDDEN = {
    'PATHEXT', 'PATH', 'COMSPEC', 'PSMODULEPATH',
    'NODEFAULTCURRENTDIRECTORYINEXEPATH', 'BASH_ENV',
    'LD_PRELOAD', 'LD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES',
    'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH',
}

# Writes whose variable name is computed at run time, keyed by the write
# line with surrounding whitespace removed.
DYNAMIC_WRITERS = {
    # "Source env.ps1 + persist env (windows-diy)" forwards the variables the
    # consuming project's own env.ps1 sets, the environment its developers
    # get locally. Its PATH entries already go through $GITHUB_PATH.
    'Add-Content -Path $env:GITHUB_ENV -Value "$name<<$eof"':
        'windows-diy env.ps1 delta',
    'Add-Content -Path $env:GITHUB_ENV -Value $value':
        'windows-diy env.ps1 delta: the multi-line value',
    'Add-Content -Path $env:GITHUB_ENV -Value $eof':
        'windows-diy env.ps1 delta: the multi-line terminator',
    'Add-Content -Path $env:GITHUB_ENV -Value "$name=$value"':
        'windows-diy env.ps1 delta',
}

# Writes the scan must find, so that a scan which silently stopped matching
# anything cannot pass. One per syntax the action uses.
KNOWN_EXPORTS = {
    'REPRO_BINARY_CACHE_URL',   # echo inside { ... } >> "$GITHUB_ENV"
    'REPRO_STORE_ROOT',         # printf ... >>"${GITHUB_ENV}"
    'REPRO_TOOL_PROVISIONING',  # echo ... >>"$GITHUB_ENV" in a script
    'RUNQUOTA_SOCKET',
}

WRITE = re.compile(r'(>>|Add-Content|Out-File|\btee\b).*GITHUB_ENV')
EXPORTED_NAME = re.compile(r'(?<![\w$])([A-Za-z_][A-Za-z0-9_]*)(?:=|<<)')
SCRIPT_REFERENCE = re.compile(r'\$\{GITHUB_ACTION_PATH\}/([\w./-]+\.(?:sh|ps1))')


def scanned_files():
    """action.yml and every script its steps run from the repository."""
    files = [ACTION]
    for relative in sorted(set(SCRIPT_REFERENCE.findall(ACTION.read_text(encoding='utf-8')))):
        path = (HERE / relative).resolve()
        if path.is_file():
            files.append(path)
    return files


def github_env_writes(text):
    """Yield (line number, write line, exported names) for each $GITHUB_ENV write.

    A write that closes a `{ ... }` group covers every line of the group, the
    form `{ echo A=1; echo B=2; } >> "$GITHUB_ENV"` takes.
    """
    lines = text.splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('#') or not WRITE.search(stripped):
            continue
        region = [stripped]
        if stripped.startswith('}'):
            depth = 0
            for earlier in range(index, -1, -1):
                candidate = lines[earlier].strip()
                depth += candidate.count('}') - candidate.count('{')
                region.append(candidate)
                if depth <= 0:
                    break
        names = set()
        for part in region:
            if not part.startswith('#'):
                names.update(EXPORTED_NAME.findall(part))
        yield index + 1, stripped, names


def exports_in(text):
    """Return (exported names, dynamic write lines) for one file's text."""
    names, dynamic = set(), []
    for _, stripped, found in github_env_writes(text):
        names.update(found)
        if not found:
            dynamic.append(stripped)
    return names, dynamic


def forbidden(names):
    return sorted(name for name in names if name.upper() in FORBIDDEN)


def installer_body():
    step = ACTION.read_text(encoding='utf-8').split('    - name: ' + STEP + '\n', 1)[1]
    step = step.split('    - name: ', 1)[0]
    body = step.split('      run: |\n', 1)[1]
    return '\n'.join(line[8:] if line.startswith('        ') else line
                      for line in body.splitlines()) + '\n'


def parse_github_env(text):
    """The variables a runner would set from a $GITHUB_ENV file."""
    result, lines = {}, iter(text.splitlines())
    for line in lines:
        if '<<' in line and ('=' not in line or line.index('<<') < line.index('=')):
            name, delimiter = line.split('<<', 1)
            value = []
            for continuation in lines:
                if continuation == delimiter:
                    break
                value.append(continuation)
            result[name] = '\n'.join(value)
        elif '=' in line:
            name, value = line.split('=', 1)
            result[name] = value
    return result


class StaticGithubEnvWrites(unittest.TestCase):
    def test_the_scan_finds_the_known_exports(self):
        names = set()
        for path in scanned_files():
            names.update(exports_in(path.read_text(encoding='utf-8'))[0])
        self.assertTrue(KNOWN_EXPORTS <= names, sorted(KNOWN_EXPORTS - names))

    def test_the_scan_catches_the_pathext_export(self):
        # The line the action carried until the leak was found.
        old = ('echo "PATHEXT=.PS1;.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;'
                '.WSH;.MSC;.CPL" >> "$GITHUB_ENV"\n')
        self.assertEqual(forbidden(exports_in(old)[0]), ['PATHEXT'])
        grouped = '{\n  echo "A=1"\n  echo "LD_PRELOAD=/x.so"\n} >> "$GITHUB_ENV"\n'
        self.assertEqual(forbidden(exports_in(grouped)[0]), ['LD_PRELOAD'])
        pwsh = 'Add-Content -Path $env:GITHUB_ENV -Value "ComSpec=C:\\x.exe"\n'
        self.assertEqual(forbidden(exports_in(pwsh)[0]), ['ComSpec'])

    def test_no_write_exports_a_process_resolution_variable(self):
        for path in scanned_files():
            names, _ = exports_in(path.read_text(encoding='utf-8'))
            self.assertEqual(forbidden(names), [], path)

    def test_every_dynamic_write_is_justified(self):
        for path in scanned_files():
            for stripped in exports_in(path.read_text(encoding='utf-8'))[1]:
                self.assertIn(stripped, DYNAMIC_WRITERS,
                              f'{path}: a $GITHUB_ENV write with no literal name')


class InstallerStepGithubEnv(unittest.TestCase):
    def setUp(self):
        self.bash = shutil.which('bash')
        if self.bash is None:
            self.fail('bash is not on PATH; this test runs the real step')
        temporary = tempfile.TemporaryDirectory(prefix='github-env-exports-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = self.root / 'install-wrapper.sh'
        self.script.write_text(installer_body(), encoding='utf-8', newline='\n')
        self.consumer = self.root / 'consumer'
        self.consumer.mkdir()
        self.path = os.environ['PATH']
        if not WINDOWS:
            stand_in = self.root / 'stand-in'
            stand_in.mkdir()
            cygpath = stand_in / 'cygpath'
            cygpath.write_text('#!/bin/sh\nfor last; do :; done\nprintf "%s\\n" "$last"\n')
            cygpath.chmod(0o755)
            self.path = str(stand_in) + os.pathsep + self.path
        elif shutil.which('cygpath') is None:
            self.fail('cygpath is not on PATH; run from Git Bash on Windows')

    def install(self, runner_os):
        """Run the step as a `runner_os` job; return the job's GITHUB_ENV text."""
        run_root = self.root / runner_os
        (run_root / 'runner-temp').mkdir(parents=True)
        github_env = run_root / 'github-env'
        github_path = run_root / 'github-path'
        github_env.write_text('')
        github_path.write_text('')
        environment = dict(os.environ, PATH=self.path, RUNNER_OS=runner_os,
                            RUNNER_TEMP=str(run_root / 'runner-temp'),
                            GITHUB_ENV=str(github_env), GITHUB_PATH=str(github_path),
                            MCL_CONSUMER_ROOT=str(self.consumer).replace('\\', '/'))
        run = subprocess.run([self.bash, str(self.script)], cwd=self.consumer,
                              env=environment, text=True, capture_output=True,
                              timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        # The step ran to its end: it published the wrapper directory.
        self.assertEqual(len(github_path.read_text().splitlines()), 1)
        return github_env.read_text(encoding='utf-8')

    def test_windows_job_exports_no_process_resolution_variable(self):
        exported = parse_github_env(self.install('Windows'))
        self.assertEqual(forbidden(exported), [], exported)

    def test_linux_job_exports_no_process_resolution_variable(self):
        exported = parse_github_env(self.install('Linux'))
        self.assertEqual(forbidden(exported), [], exported)

    @unittest.skipUnless(WINDOWS, 'cmd.exe exists only on Windows')
    def test_cmd_runs_the_cmd_shim_beside_a_ps1_one_in_the_job_environment(self):
        job = dict(os.environ)
        for name, value in parse_github_env(self.install('Windows')).items():
            for key in [key for key in job if key.upper() == name.upper()]:
                del job[key]
            job[name] = value
        shims = self.root / 'node_modules' / '.bin'
        shims.mkdir(parents=True)
        (shims / 'napi.cmd').write_text('@echo napi.cmd ran %*\r\n')
        (shims / 'napi.ps1').write_text('Write-Output "napi.ps1 ran"\r\n')
        job['PATH'] = str(shims) + os.pathsep + job.get('PATH', '')
        # As npx starts a package command: `cmd.exe /d /s /c "<command>"`.
        run = subprocess.run(['cmd.exe', '/d', '/s', '/c', 'napi --version'],
                              cwd=self.root, env=job, text=True,
                              capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.strip(), 'napi.cmd ran --version')


if __name__ == '__main__':
    unittest.main()
