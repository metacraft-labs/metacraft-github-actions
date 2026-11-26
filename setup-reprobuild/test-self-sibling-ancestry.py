"""No mocks: a shallow consumer that the selected source pins is made acceptable.

Property protected: on the source route, when the Reprobuild checkout being
built pins the CONSUMER itself as a sibling, the step `Reveal the pin's
ancestry in a consumer the source pins` leaves a depth-1 consumer checkout in
which the engine's own probe,

    GIT_NO_LAZY_FETCH=1 git -C <consumer> merge-base --is-ancestor <pin> HEAD

succeeds whenever the pin really is in HEAD's history -- without moving HEAD,
any ref or the working tree. A consumer the source does not pin is not
touched at all (its remote is never contacted).

Regression test for gosti run 45782702955 (Linux x64 and macOS, reprobuild
37a109c4 built from source): reprobuild's `.github/sibling-repos` pins
`gosti=cf435b3c...`, the engine anchors `../gosti/src` at the consumer's
parent and so finds the consumer `/home/runner/work/gosti/gosti` as that
sibling, and `setup-dev-env`'s `repro exec` stopped at

    no acceptable source for GOSTI_SRC (gosti.nim): .../.reprobuild-src pins
    'gosti' at cf435b3ca8ab..., but the sibling is at 71c8fd805e98, which is
    not at or ahead of the revision cf435b3ca8ab this repository pins

although cf435b3c is seven commits behind 71c8fd80: `actions/checkout` had
fetched one commit.

Real Git repositories, served over `file://` (which, unlike a local-path
clone, honours `--depth`), stand in for GitHub. The bare remote allows any
reachable commit id in a `want`, as github.com does. The step's own `run:`
body is executed from action.yml, with a PATH holding only bash and git: the
self-hosted macOS runners reach no coreutils at this point. No engine is
built; the engine's acceptance test is the probe above, copied from reprobuild
`observeSiblingCheckout`.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
STEP = "Reveal the pin's ancestry in a consumer the source pins"


def step_block(name):
    lines = (HERE / 'action.yml').read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_run(name):
    block = step_block(name)
    run = next(line for line in block if line.startswith('      run: '))
    return run[len('      run: '):] + '\n'


class SelfSiblingAncestry(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='repro-self-sibling-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.gitconfig = self.root / 'gitconfig'
        self.gitconfig.write_text('[protocol "file"]\n\tallow = always\n'
                                  '[init]\n\tdefaultBranch = dev\n')
        self.env = {
            'HOME': str(self.root), 'LC_ALL': 'C',
            'GIT_CONFIG_GLOBAL': str(self.gitconfig), 'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
            'PATH': os.environ['PATH'],
        }
        # bash and git only, as on the self-hosted macOS runners. $BASH32
        # names a Bash 3.2 to run the step with (the `bash32-parse` job of
        # test.yml builds one), as macOS's /bin/bash would.
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        for tool in ('bash', 'git'):
            found = (os.environ.get('BASH32') if tool == 'bash' else None) or shutil.which(tool)
            self.assertIsNotNone(found, 'the suite needs ' + tool)
            (self.tools / tool).symlink_to(found)

    def git(self, *args, check=True, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd, env=self.env, text=True,
                              capture_output=True, check=check)

    def remote(self, name, commits):
        """A bare remote whose `dev` has `commits` commits; their ids, oldest first."""
        work = self.root / ('author-' + name)
        self.git('init', str(work))
        ids = []
        for n in range(commits):
            (work / 'file').write_text('%s %d\n' % (name, n))
            self.git('-C', str(work), 'add', 'file')
            self.git('-C', str(work), 'commit', '-q', '-m', 'commit %d' % n)
            ids.append(self.git('-C', str(work), 'rev-parse', 'HEAD').stdout.strip())
        bare = self.root / 'remotes' / (name + '.git')
        bare.parent.mkdir(exist_ok=True)
        self.git('clone', '-q', '--bare', str(work), str(bare))
        self.git('-C', str(bare), 'config', 'uploadpack.allowAnySHA1InWant', 'true')
        self.author = work
        return bare, ids

    def side_commit(self, bare):
        """A commit on another branch of `bare`, not in `dev`'s history."""
        self.git('-C', str(self.author), 'checkout', '-q', '-b', 'side', 'HEAD~1')
        (self.author / 'side').write_text('side\n')
        self.git('-C', str(self.author), 'add', 'side')
        self.git('-C', str(self.author), 'commit', '-q', '-m', 'side')
        rev = self.git('-C', str(self.author), 'rev-parse', 'HEAD').stdout.strip()
        self.git('-C', str(self.author), 'push', '-q', str(bare), 'side')
        return rev

    def consumer(self, bare, name):
        """`actions/checkout`'s default: a depth-1 clone at
        `<work>/<name>/<name>`, which is also GITHUB_WORKSPACE."""
        workspace = self.root / 'work' / name / name
        workspace.parent.mkdir(parents=True)
        self.git('clone', '-q', '--depth', '1', '--branch', 'dev',
          'file://' + str(bare), str(workspace))
        return workspace

    def source(self, workspace, sibling_repos='', repro_lock='', flake_lock=None):
        source = workspace / '.reprobuild-src'
        (source / '.github').mkdir(parents=True)
        (source / '.github' / 'sibling-repos').write_text(sibling_repos)
        if repro_lock:
            (source / 'repro.lock').write_text(repro_lock)
        if flake_lock is not None:
            (source / 'flake.lock').write_text(json.dumps(flake_lock, indent=2))
        return source

    def break_remote(self, checkout):
        """Point origin at nothing, so that any fetch fails."""
        absent = 'file://' + str(self.root / 'absent.git')
        self.git('-C', str(checkout), 'remote', 'set-url', 'origin', absent)

    def probe(self, checkout, pin):
        """reprobuild `observeSiblingCheckout`'s acceptance question."""
        env = dict(self.env, GIT_NO_LAZY_FETCH='1')
        argv = ['git', '-C', str(checkout), 'merge-base', '--is-ancestor', pin, 'HEAD']
        return subprocess.run(argv, env=env, capture_output=True).returncode == 0

    def state(self, checkout):
        return (self.git('-C', str(checkout), 'rev-parse', 'HEAD').stdout,
                self.git('-C', str(checkout), 'for-each-ref').stdout,
                self.git('-C', str(checkout), 'status', '--porcelain',
                  '--untracked-files=all', '--ignored').stdout)

    def run_step(self, workspace, extra=None):
        env = dict(self.env)
        env.update({
            'PATH': str(self.tools),
            'GITHUB_ACTION_PATH': str(HERE),
            'GITHUB_WORKSPACE': str(workspace),
            'MCL_CONSUMER_DIRECTORY': '.',
            'MCL_WORKSPACE_DIRECTORY': '.',
            'REPROBUILD_SOURCE_DIRECTORY': str(workspace / '.reprobuild-src'),
        })
        env.update(extra or {})
        argv = ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', step_run(STEP)]
        return subprocess.run(argv, cwd=workspace, env=env, text=True,
                              capture_output=True, timeout=120)

    def test_the_step_runs_under_the_requested_bash(self):
        if not os.environ.get('BASH32'):
            self.skipTest('BASH32 is not set')
        argv = [str(self.tools / 'bash'), '-c', 'echo "${BASH_VERSION}"']
        version = subprocess.run(argv, env=self.env, text=True, capture_output=True, check=True)
        self.assertTrue(version.stdout.startswith('3.'), version.stdout)

    def test_step_is_on_the_source_route_only(self):
        block = '\n'.join(step_block(STEP))
        self.assertIn("if: ${{ steps.decide.outputs.need-source == 'true' }}", block)
        lines = (HERE / 'action.yml').read_text().splitlines()
        names = [line[len('    - name: '):] for line in lines if line.startswith('    - name: ')]
        self.assertLess(names.index('Provision selected Reprobuild source dependencies'),
                        names.index(STEP))
        self.assertLess(names.index(STEP), names.index('Build repro CLI (Linux/macOS)'))
        self.assertLess(names.index(STEP), names.index('Build repro CLI (Windows)'))

    def test_gosti_shape_pin_seven_commits_behind_head(self):
        bare, ids = self.remote('gosti', 9)
        pin = ids[1]  # HEAD is ids[8], seven commits ahead of the pin
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='# comment\nio-mon=%s\n\ngosti=%s\n' % ('a' * 40, pin))
        # The refusal reproduces: a depth-1 checkout cannot show the pin.
        self.assertFalse(self.probe(workspace, pin))
        before = self.state(workspace)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)
        self.assertEqual(self.state(workspace), before)
        self.assertNotIn('::warning::', result.stdout + result.stderr)
        self.assertIn('deepened by 16', result.stdout)

    def test_a_pin_far_behind_head_is_reached_by_further_deepening(self):
        bare, ids = self.remote('gosti', 60)
        pin = ids[2]
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='gosti=%s\n' % pin)
        self.assertFalse(self.probe(workspace, pin))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)
        self.assertIn('deepened by 128', result.stdout)

    def test_unshallow_is_the_last_resort(self):
        bare, ids = self.remote('gosti', 12)
        pin = ids[0]
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='gosti=%s\n' % pin)
        result = self.run_step(workspace, {'REVEAL_DEEPEN_STEPS': '1 2'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)
        self.assertIn('complete history', result.stdout)
        self.assertEqual(self.git('-C', str(workspace), 'rev-parse',
                                  '--is-shallow-repository').stdout.strip(), 'false')

    def test_repro_lock_is_read_before_the_flake_lock_and_sibling_repos(self):
        bare, ids = self.remote('gosti', 9)
        pin = ids[3]
        workspace = self.consumer(bare, 'gosti')
        other = self.side_commit(bare)
        lock = ('schema = "reprobuild.solved-graph-lock.v3"\n[lock]\n'
                'packages = [{ name = "gosti", version = "1.0.0", source = "gosti" }]\n'
                'deps = [{ name = "gosti", coord_kind = "vcs", url = "https://github.com/x/gosti",'
                ' revision = "%s", integrity = "" }]\n' % pin)
        self.source(workspace, sibling_repos='gosti=%s\n' % other, repro_lock=lock,
                    flake_lock=self.flake({'gosti-src': ('gosti', other)}))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(pin, result.stdout)
        self.assertNotIn(other, result.stdout)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)

    def flake(self, inputs):
        nodes = {'root': {'inputs': {}}}
        for alias, (repo, rev) in inputs.items():
            nodes['root']['inputs'][alias] = alias
            locked = {'type': 'github', 'owner': 'Metacraft-Labs', 'repo': repo, 'rev': rev}
            nodes[alias] = {'locked': locked, 'original': {}}
        return {'nodes': nodes, 'root': 'root', 'version': 7}

    def test_a_direct_flake_input_pins_the_consumer(self):
        bare, ids = self.remote('gosti', 9)
        pin = ids[4]
        workspace = self.consumer(bare, 'gosti')
        other = self.side_commit(bare)
        self.source(workspace, sibling_repos='gosti=%s\n' % other,
                    flake_lock=self.flake({'gosti-src': ('Gosti', pin)}))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(pin, result.stdout)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)

    def test_flake_inputs_that_disagree_fall_through_to_sibling_repos(self):
        # reprobuild `flakeLockDirectPins`: two direct inputs fetching one
        # repository at different revisions are no pin, so
        # `pinnedSiblingRevisionIn` reads `.github/sibling-repos` next.
        bare, ids = self.remote('gosti', 9)
        pin = ids[5]
        workspace = self.consumer(bare, 'gosti')
        other = self.side_commit(bare)
        self.source(workspace, sibling_repos='gosti=%s\n' % pin,
                    flake_lock=self.flake({
                        'gosti-a': ('gosti', other),
                        'gosti-b': ('gosti', ids[0]),
                    }))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(pin, result.stdout)
        self.assertNotIn(other, result.stdout)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)

    def test_a_transitive_flake_node_is_not_a_pin(self):
        # Only inputs the ROOT names count (`flakeLockDirectPins`); a node
        # another input brings in is that input's choice.
        bare, ids = self.remote('gosti', 9)
        pin = ids[5]
        workspace = self.consumer(bare, 'gosti')
        other = self.side_commit(bare)
        lock = self.flake({'io-mon-src': ('io-mon', 'b' * 40)})
        lock['nodes']['io-mon-src']['inputs'] = {'gosti': 'gosti_2'}
        lock['nodes']['gosti_2'] = {'locked': {
            'type': 'github', 'owner': 'metacraft-labs', 'repo': 'gosti', 'rev': other,
        }}
        self.source(workspace, sibling_repos='gosti=%s\n' % pin, flake_lock=lock)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(pin, result.stdout)
        self.assertNotIn(other, result.stdout)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)

    def test_a_not_equal_line_with_crlf_endings_pins_the_consumer(self):
        # `name!=<sha>` is the other spelling `pinnedSiblingRevisionIn`
        # accepts; a file checked out with CRLF endings reads the same.
        bare, ids = self.remote('gosti', 9)
        pin = ids[2]
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace,
                    sibling_repos='# c\r\ngosti-extra=%s\r\n  gosti != %s \r\n' % ('c' * 40, pin))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # `gosti ` (with the blank) is not the name `gosti`, as in the engine,
        # which compares the unstripped head of the line.
        self.assertEqual(result.stdout + result.stderr, '')
        (workspace / '.reprobuild-src' / '.github' / 'sibling-repos').write_text(
            '# c\r\ngosti-extra=%s\r\ngosti!= %s \r\n' % ('c' * 40, pin))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(pin, result.stdout)
        self.assertTrue(self.probe(workspace, pin), result.stdout + result.stderr)

    def test_a_consumer_the_source_does_not_pin_is_not_touched(self):
        bare, ids = self.remote('other', 5)
        workspace = self.consumer(bare, 'other')
        self.source(workspace, sibling_repos='gosti=%s\n' % ids[0])
        # Any fetch would fail: the remote is gone.
        self.break_remote(workspace)
        shallow = (workspace / '.git' / 'shallow').read_text()
        before = self.state(workspace)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertEqual((workspace / '.git' / 'shallow').read_text(), shallow)
        self.assertEqual(self.state(workspace), before)

    def test_a_branch_valued_pin_is_left_to_the_engine(self):
        bare, _ = self.remote('gosti', 5)
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='gosti=dev\n')
        shallow = (workspace / '.git' / 'shallow').read_text()
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('not a commit id', result.stdout)
        self.assertEqual((workspace / '.git' / 'shallow').read_text(), shallow)

    def test_a_pin_off_heads_line_is_still_the_engines_refusal(self):
        bare, _ = self.remote('gosti', 6)
        workspace = self.consumer(bare, 'gosti')
        off = self.side_commit(bare)
        self.source(workspace, sibling_repos='gosti=%s\n' % off)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.probe(workspace, off))
        self.assertIn('::warning::', result.stdout)
        self.assertIn('not at or ahead of it even with its complete history', result.stdout)

    def test_an_unreachable_remote_warns_and_leaves_the_refusal_to_the_engine(self):
        bare, ids = self.remote('gosti', 6)
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='gosti=%s\n' % ids[0])
        self.break_remote(workspace)
        before = self.state(workspace)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('::warning::', result.stdout)
        self.assertIn('fetch-depth: 0', result.stdout)
        self.assertEqual(self.state(workspace), before)

    def test_an_already_visible_pin_fetches_nothing(self):
        bare, ids = self.remote('gosti', 4)
        workspace = self.consumer(bare, 'gosti')
        self.source(workspace, sibling_repos='gosti=%s\n' % ids[-1])  # the pin IS HEAD
        self.break_remote(workspace)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already shows', result.stdout)
        self.assertNotIn('::warning::', result.stdout)


if __name__ == '__main__':
    unittest.main()
