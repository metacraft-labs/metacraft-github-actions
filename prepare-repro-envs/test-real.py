"""Real SDK provisioning through an owned HTTP expiry boundary.

Only the external archive service is substituted. It serves the declared
SHA256-pinned archive, then returns 401 at a deterministic expiry barrier.
The real SDK, compiler, HTTP client, extraction and environment activation run
unchanged. --legacy-workflow executes the old actual preflight to demonstrate
its late fetch, rather than failing because the new helper is absent.
"""
import argparse
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--repro', type=Path, required=True)
p.add_argument('--legacy-workflow', type=Path)
p.add_argument('--report-directory', type=Path, required=True)
a = p.parse_args()
repro = a.repro.resolve(strict=True)
a.report_directory.mkdir(parents=True, exist_ok=True)
print('selected SDK:', repro, flush=True)
subprocess.run([str(repro), '--version'], check=True)
commands = []


def run(argv, env, cwd):
  stem = a.report_directory / str(len(commands))
  commands.append(argv)
  with stem.with_suffix('.stdout').open('wb') as out, stem.with_suffix('.stderr').open('wb') as err:
    result = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=err)
  output = stem.with_suffix('.stdout').read_text(errors='replace')
  error = stem.with_suffix('.stderr').read_text(errors='replace')
  print('command', len(commands) - 1, 'exit', result.returncode, flush=True)
  return result.returncode, output, error


class Handler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    code = 401 if self.server.expired else 200
    self.server.requests.append((self.path, code))
    self.send_response(code)
    self.end_headers()
    self.wfile.write(b'Bad credentials' if code == 401 else self.server.archives[self.path])

  def log_message(self, *args):
    pass


with tempfile.TemporaryDirectory(prefix='prepare-real-') as temporary:
  root = Path(temporary)
  server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
  server.expired, server.requests, server.archives = False, [], {}
  thread = threading.Thread(target=server.serve_forever, daemon=True)
  thread.start()
  try:
    env = dict(os.environ, PATH=str(repro.parent) + os.pathsep + os.environ['PATH'],
                REPRO_STORE_ROOT=str(root / 'store'), REPRO_CACHE_DISABLE='1')
    env.pop('REPRO_TOOL_PROVISIONING', None)
    projects = []
    for index in range(2):
      project = root / ('project ' + str(index))
      project.mkdir()
      tool, stamp = 'ownedtool' + str(index), 'REAL-TOOL-' + str(index)
      content = ('#!' + shutil.which('bash') + '\nprintf "%s\\n" ' + stamp + '\n').encode()
      data = io.BytesIO()
      with tarfile.open(fileobj=data, mode='w:gz') as archive:
        member = tarfile.TarInfo('bin/' + tool)
        member.size, member.mode = len(content), 0o755
        archive.addfile(member, io.BytesIO(content))
      archive_path = '/' + tool + '.tar.gz'
      server.archives[archive_path] = data.getvalue()
      url = 'http://127.0.0.1:' + str(server.server_port) + archive_path
      digest = hashlib.sha256(data.getvalue()).hexdigest()
      (project / 'repro.nim').write_text(
        'import repro_project_dsl\npackage ' + tool + ':\n  provisioning:\n'
        '    tarball url = "' + url + '", sha256 = "' + digest + '", '
        'executablePath = "bin/' + tool + '", archiveType = "tar.gz"\n'
        'package fixture:\n  defaultToolProvisioning "tarball"\n'
        '  uses:\n    "' + tool + '"\n  devEnv:\n'
        '    setEnv "OWNED_PREFLIGHT", "' + stamp + '"\n')
      projects.append((project, tool, stamp, archive_path))
    if a.legacy_workflow:
      text = a.legacy_workflow.read_text()
      name = '      - name: Fetch every flake input later steps evaluate, while the token is valid\n'
      block = text.split(name, 1)[1].split('\n      - name:', 1)[0]
      body = block.split('        run: |\n', 1)[1]
      script = root / 'legacy-guard.sh'
      script.write_text('\n'.join(line[10:] for line in body.splitlines()) + '\n')
      code, out, err = run(['bash', str(script)], dict(env, CT_DIR=str(projects[0][0]),
                            RECORDER_REPO='unused-recorder'), root)
      assert code == 0, 'legacy guard failed for another reason:\n' + out + err
    else:
      env['REPRO_PREFLIGHT_PROJECTS'] = '\n'.join(str(row[0]) for row in projects)
      code, out, err = run(['bash', str(Path(__file__).resolve().with_name('prepare.sh'))], env, root)
      assert code == 0, 'preparation failed:\n' + out + err
      for project, tool, stamp, archive_path in projects:
        assert (archive_path, 200) in server.requests, 'not provisioned: ' + tool
    server.expired = True
    before = len(server.requests)
    for project, tool, stamp, archive_path in projects:
      code, out, err = run([str(repro), 'exec', str(project), '--', 'bash', '-e', '-c',
                            'test "$OWNED_PREFLIGHT" = ' + stamp + '; ' + tool], env, root)
      assert code == 0 and stamp in out.splitlines(), (
        'late use fetched after credential expiry instead of using prepared tools:\n' + out + err)
    assert len(server.requests) == before, 'late use attempted a credentialed fetch'
    print('PASS: real tools execute after HTTP credential expiry without refetch', flush=True)
    # Original issue's C bootstrap path is fatal before activation, unlike
    # the SDK's deliberately optional per-tool development-shell fallback.
    # A real unusable compiler file provokes that boundary without mocking a
    # compiler, depending on external credentials or changing compiler choice
    # in production. The override is confined to this refusing fixture.
    broken = root / 'unusable compiler'
    broken.write_text('this is not a C compiler\n')
    broken.chmod(0o755)
    env.update(REPRO_BOOTSTRAP_CC=str(broken), REPRO_PREFLIGHT_PROJECTS=str(projects[0][0]))
    code, out, err = run(['bash', str(Path(__file__).resolve().with_name('prepare.sh'))], env, root)
    assert code != 0 and 'infrastructure' in err and str(broken) in err, out + err
    assert 'prepared:' not in out, 'bootstrap refusal received a preparation verdict'
    assert 'activated command witness' not in out, 'bootstrap refusal executed the payload'
    print('PASS: real C bootstrap refusal stops preparation as infrastructure', flush=True)
  finally:
    (a.report_directory / 'http.json').write_text(json.dumps(server.requests, indent=2) + '\n')
    server.shutdown()
    server.server_close()
    thread.join()
