"""Shared orchestration controls; SDK realization is covered by test-real.py.

Nix and Repro argument recorders isolate action dispatch, shell selection,
status preservation and witness validation. They do not claim to provision
anything. The real SDK/HTTP suite is required separately for that boundary.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class Preparation(unittest.TestCase):
  def test_dispatch_and_refusals(self):
    with tempfile.TemporaryDirectory(prefix='prepare-dispatch-') as temporary:
      root = Path(temporary)
      bin_dir = root / 'bin'
      bin_dir.mkdir()
      projects = [root / 'project one', root / 'project two']
      for project in projects:
        project.mkdir()
        (project / 'repro.nim').write_text('fixture selected by real integration test\n')
      repro = bin_dir / 'repro'
      repro.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
mode=os.environ.get('MODE','')
if mode=='401':
  print('HTTP error 401: Bad credentials', file=sys.stderr); sys.exit(37)
if mode=='no-witness': sys.exit(0)
sys.exit(subprocess.run(sys.argv[sys.argv.index('--')+1:]).returncode)
''')
      repro.chmod(0o755)
      env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                  CALLS=str(root / 'calls'), RUNNER_TEMP=str(root),
                  REPRO_PREFLIGHT_PROJECTS='\n'.join(map(str, projects)))

      def run(mode=''):
        return subprocess.run(['bash', str(HERE / 'prepare.sh')], env=dict(env, MODE=mode),
                              text=True, capture_output=True)

      result = run()
      self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
      calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
      self.assertEqual([call[:3] for call in calls], [['exec', str(project), '--'] for project in projects])
      self.assertEqual(result.stdout.count('prepared:'), 2)
      result = run('401')
      self.assertEqual(result.returncode, 37)
      self.assertIn('infrastructure', result.stderr)
      self.assertIn('HTTP error 401', result.stderr)
      self.assertNotIn('prepared:', result.stdout)
      result = run('no-witness')
      self.assertNotEqual(result.returncode, 0)
      self.assertIn('witness', result.stderr)
      self.assertNotIn('prepared:', result.stdout)
      # The Nix recorder isolates action dispatch; real SDK qualification is
      # separate. The shell selector is data even when it contains spaces.
      nix = bin_dir / 'nix'
      nix.write_text("#!/usr/bin/env python3\nimport json,os,subprocess,sys\nwith open(os.environ['NIX_CALLS'], 'a') as f: f.write(json.dumps([os.getcwd(), *sys.argv[1:]])+'\\n')\nif os.environ.get('NIX_REFUSE'):\n print('HTTP error 401: selected shell input', file=sys.stderr); sys.exit(41)\nsys.exit(subprocess.run(sys.argv[sys.argv.index('--command')+1:]).returncode)\n")
      nix.chmod(0o755)
      outer_env = dict(env, REPRO_PREFLIGHT_NIX_SHELL='path:project with spaces#ci',
                        REPRO_PREFLIGHT_WORKING_DIRECTORY=str(root),
                        GITHUB_ACTION_PATH=str(HERE), NIX_CALLS=str(root / 'nix-calls'))
      body = (HERE / 'action.yml').read_text().split('      run: ', 1)[1].strip()
      result = subprocess.run(['bash', '-c', body], env=outer_env, text=True, capture_output=True)
      self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
      nix_call = json.loads((root / 'nix-calls').read_text().splitlines()[0])
      self.assertEqual(nix_call.pop(0), str(root))
      self.assertEqual(nix_call[0:2], ['develop', '--profile'])
      self.assertEqual(nix_call[3:], ['path:project with spaces#ci', '--command', 'bash', str(HERE / 'prepare.sh')])
      self.assertTrue(Path(nix_call[2]).parent.is_dir())
      result = subprocess.run(['bash', '-c', body], env=dict(outer_env, NIX_REFUSE='1'),
                              text=True, capture_output=True)
      self.assertEqual(result.returncode, 41)
      self.assertIn('infrastructure', result.stderr)
      self.assertIn('HTTP error 401', result.stderr)
      self.assertNotIn('prepared:', result.stdout)
      env['REPRO_PREFLIGHT_PROJECTS'] = ''
      self.assertNotEqual(run().returncode, 0)
      env['REPRO_PREFLIGHT_PROJECTS'] = str(root / 'absent')
      self.assertNotEqual(run().returncode, 0)


if __name__ == '__main__':
  unittest.main()
