"""No mocks: shallow siblings that the selected source pins are made acceptable.

Property protected: on the source route, for every workspace sibling the
engine judges -- the CONSUMER itself when the Reprobuild checkout being built
pins it, and a sibling the workflow cloned next to it -- the step `Reveal the
pin's ancestry in the siblings the source pins` (and setup-dev-env's run of
the same script after its own sibling provisioning) leaves a depth-1 checkout
in which the engine's own probe,

    GIT_NO_LAZY_FETCH=1 git -C <sibling> merge-base --is-ancestor <pin> HEAD

succeeds whenever the pin really is in HEAD's history -- without moving HEAD,
any ref or the working tree. A checkout the source does not pin, or that the
engine does not judge, is not touched at all (its remote is never contacted).

Regression test for io-mon runs 45869475954 and 45869479858 (io-mon `agents`
3bfa85d7, reprobuild 37a109c4 built from source): clone-siblings put io-mon's
lock revision of nim-stackable-hooks, ec6b02d4, at `../nim-stackable-hooks`
with depth 1, 37a109c4's repro.lock pins it at c34e3252 (eleven commits
behind), and `repro exec` stopped at

    no acceptable source for STACKABLE_HOOKS_SRC (stackable_hooks.nim):
    .../.reprobuild-src pins 'nim-stackable-hooks' at c34e3252..., but the
    sibling is at ec6b02d45180, which is not at or ahead of the revision
    c34e3252d413 this repository pins

And for gosti run 45782702955 (Linux x64 and macOS, reprobuild
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
STEP = "Reveal the pin's ancestry in the siblings the source pins"
DEV_ENV = HERE.parent / 'setup-dev-env'
DEV_ENV_STEP = "Reveal the pin's ancestry in the siblings the Reprobuild source pins"


def step_names(action_dir):
    lines = (action_dir / 'action.yml').read_text().splitlines()
    return [line[len('    - name: '):] for line in lines if line.startswith('    - name: ')]


def step_block(name, action_dir=HERE):
    lines = (action_dir / 'action.yml').read_text().splitlines()
    start = lines.index('    - name: ' + name)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith('    - name: ')), len(lines))
    return lines[start:end]


def step_run(name, action_dir=HERE):
    block = step_block(name, action_dir)
    run = next(line for line in block if line.startswith('      run: '))
    return run[len('      run: '):] + '\n'


class SiblingPinAncestry(unittest.TestCase):
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

    def sibling(self, bare, consumer, name, rev, parent=None):
        """A sibling as clone-siblings (authenticated-clone.sh `--shallow`
        with a revision) leaves it: `git init`, `origin`, a depth-1 fetch of
        exactly <rev>, HEAD detached there. At `<consumer>/../<name>` unless
        <parent> names another directory (reprobuild-provision clones into the
        workspace directory)."""
        dest = (parent or consumer.parent) / name
        self.git('init', '-q', str(dest))
        self.git('-C', str(dest), 'remote', 'add', 'origin', 'file://' + str(bare))
        self.git('-C', str(dest), 'fetch', '-q', '--depth', '1', 'origin', rev)
        self.git('-C', str(dest), 'checkout', '-q', '--detach', 'FETCH_HEAD')
        return dest

    def lock(self, pins):
        """A repro.lock whose `deps` pin each name of <pins> at its revision."""
        deps = ', '.join(
            '{ name = "%s", coord_kind = "vcs", url = "https://github.com/x/%s",'
            ' revision = "%s", integrity = "" }' % (name, name, rev)
            for name, rev in pins.items())
        return ('schema = "reprobuild.solved-graph-lock.v3"\n[lock]\n'
                'deps = [%s]\n' % deps)

    def run_step(self, workspace, extra=None, action_dir=HERE, step=STEP):
        env = dict(self.env)
        env.update({
            'PATH': str(self.tools),
            'GITHUB_ACTION_PATH': str(action_dir),
            'GITHUB_WORKSPACE': str(workspace),
            'MCL_CONSUMER_DIRECTORY': '.',
            'MCL_WORKSPACE_DIRECTORY': '.',
            'REPROBUILD_SOURCE_DIRECTORY': str(workspace / '.reprobuild-src'),
        })
        env.update(extra or {})
        argv = ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                step_run(step, action_dir)]
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
        names = step_names(HERE)
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


    def test_setup_dev_env_reveals_after_every_sibling_route(self):
        # On the repro.lock route the siblings are provisioned AFTER
        # setup-reprobuild, so its own run of the script cannot see them;
        # setup-dev-env runs it again once every route has cloned, after the
        # job-scoped Git credential, and before the first `repro exec`.
        block = '\n'.join(step_block(DEV_ENV_STEP, DEV_ENV))
        self.assertIn("if: ${{ steps.repro-cli.outputs.install-source == 'source' }}", block)
        self.assertIn('../setup-reprobuild/reveal-sibling-pin-ancestry.sh', block)
        names = step_names(DEV_ENV)
        here = names.index(DEV_ENV_STEP)
        for earlier in ('Clone cross-repo siblings from the workspace lock',
                        'Install the repro CLI (reprobuild)',
                        'Provision cross-repo siblings from the committed repro.lock',
                        'Clone the siblings the repro.lock path did not provide',
                        'Configure Git authentication (reprobuild)'):
            self.assertLess(names.index(earlier), here, earlier)
        for later in ('Verify Reprobuild development-environment execution',
                      'Install dev-exec wrapper (reprobuild)'):
            self.assertLess(here, names.index(later), later)

    def io_mon_shape(self):
        """io-mon runs 45869475954/45869479858: a depth-1 consumer io-mon and
        a depth-1 sibling nim-stackable-hooks eleven commits ahead of the
        revision the source's repro.lock pins for it."""
        io_mon, _ = self.remote('io-mon', 3)
        workspace = self.consumer(io_mon, 'io-mon')
        hooks, ids = self.remote('nim-stackable-hooks', 14)
        pin, head = ids[1], ids[12]  # HEAD is not the remote's tip either
        sibling = self.sibling(hooks, workspace, 'nim-stackable-hooks', head)
        self.source(workspace, repro_lock=self.lock({'nim-stackable-hooks': pin}),
                    flake_lock=self.flake({'stackable-hooks-src': ('nim-stackable-hooks', pin)}))
        return workspace, sibling, pin

    def test_io_mon_shape_shallow_sibling_at_a_descendant_of_the_pin(self):
        workspace, sibling, pin = self.io_mon_shape()
        # The refusal reproduces: the depth-1 sibling cannot show the pin.
        self.assertFalse(self.probe(sibling, pin))
        before = (self.state(sibling), self.state(workspace))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(sibling, pin), result.stdout + result.stderr)
        self.assertEqual((self.state(sibling), self.state(workspace)), before)
        self.assertNotIn('::warning::', result.stdout + result.stderr)
        self.assertIn("the sibling 'nim-stackable-hooks'", result.stdout)
        self.assertIn('deepened by 16', result.stdout)

    def test_setup_dev_env_step_reveals_the_io_mon_shape(self):
        # The step's body as setup-dev-env runs it: from setup-dev-env's own
        # directory, reaching the script through ../setup-reprobuild.
        workspace, sibling, pin = self.io_mon_shape()
        self.assertFalse(self.probe(sibling, pin))
        result = self.run_step(workspace, action_dir=DEV_ENV, step=DEV_ENV_STEP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(sibling, pin), result.stdout + result.stderr)
        self.assertNotIn('::warning::', result.stdout + result.stderr)

    def test_a_sibling_in_the_workspace_directory_is_revealed(self):
        # reprobuild-provision clones into the workspace directory, the
        # source's parent: the engine's other workspace root.
        consumer_remote, _ = self.remote('tool', 2)
        workspace = self.consumer(consumer_remote, 'tool')
        runquota, ids = self.remote('runquota', 6)
        sibling = self.sibling(runquota, workspace, 'runquota', ids[-1], parent=workspace)
        self.source(workspace, repro_lock=self.lock({'runquota': ids[0]}))
        self.assertFalse(self.probe(sibling, ids[0]))
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(sibling, ids[0]), result.stdout + result.stderr)

    def test_every_pinned_shallow_sibling_is_revealed_in_one_run(self):
        workspace, hooks_sibling, hooks_pin = self.io_mon_shape()
        queue, ids = self.remote('nim-shm-queue', 5)
        queue_sibling = self.sibling(queue, workspace, 'nim-shm-queue', ids[-1])
        lock = self.lock({'nim-stackable-hooks': hooks_pin, 'nim-shm-queue': ids[0]})
        (workspace / '.reprobuild-src' / 'repro.lock').write_text(lock)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.probe(hooks_sibling, hooks_pin), result.stdout + result.stderr)
        self.assertTrue(self.probe(queue_sibling, ids[0]), result.stdout + result.stderr)

    def test_a_sibling_the_source_does_not_pin_is_not_touched(self):
        workspace, _, _ = self.io_mon_shape()
        gset, ids = self.remote('nim-shm-gset', 4)
        sibling = self.sibling(gset, workspace, 'nim-shm-gset', ids[-1])
        self.break_remote(sibling)
        shallow = (sibling / '.git' / 'shallow').read_text()
        before = self.state(sibling)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('nim-shm-gset', result.stdout + result.stderr)
        self.assertEqual((sibling / '.git' / 'shallow').read_text(), shallow)
        self.assertEqual(self.state(sibling), before)

    def test_a_pinned_sibling_the_engine_does_not_judge_is_not_touched(self):
        # The source pins codetracer (flake.lock, sibling-repos), but the
        # engine never judges a `../codetracer` checkout against it; deepening
        # one would fetch history nothing asks for.
        consumer_remote, _ = self.remote('tool', 2)
        workspace = self.consumer(consumer_remote, 'tool')
        codetracer, ids = self.remote('codetracer', 4)
        sibling = self.sibling(codetracer, workspace, 'codetracer', ids[-1])
        self.break_remote(sibling)
        self.source(workspace, sibling_repos='codetracer=%s\n' % ids[0],
                    repro_lock=self.lock({'codetracer': ids[0]}))
        before = self.state(sibling)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertEqual(self.state(sibling), before)

    def test_an_unreachable_sibling_remote_names_the_sibling_workaround(self):
        workspace, sibling, pin = self.io_mon_shape()
        self.break_remote(sibling)
        before = self.state(sibling)
        result = self.run_step(workspace)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('::warning::', result.stdout)
        self.assertIn('clone the sibling with its full history', result.stdout)
        self.assertNotIn('fetch-depth: 0', result.stdout)
        self.assertEqual(self.state(sibling), before)

    def test_no_source_checkout_does_nothing(self):
        workspace, sibling, pin = self.io_mon_shape()
        self.break_remote(sibling)
        result = self.run_step(workspace, {
            'REPROBUILD_SOURCE_DIRECTORY': str(workspace / 'no-such-source')})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertFalse(self.probe(sibling, pin))


if __name__ == '__main__':
    unittest.main()
