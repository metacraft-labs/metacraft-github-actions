// No mocks. These checks create real release directories and exercise transfer
// verification with missing, unexpected, corrupt and non-regular artifacts.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {seal, assemble, verifyDirectory, digest, plan} = require('./release.cjs');
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-gate-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  for (const n of ['linux.tar.gz', 'windows.zip']) fs.writeFileSync(path.join(dir, n), `payload ${n}`);
  return dir;
}
const expected = ['linux.tar.gz', 'windows.zip'];
test('a shim providing GLIBC_2.34 does not require GLIBC_2.34', () => {
  const {glibcRequirements} = require('./payload.cjs');
  assert.deepEqual(glibcRequirements(`
    12: 0000000000000000 0 FUNC GLOBAL DEFAULT UND memcpy@GLIBC_2.14 (3)
    34: 0000000000001230 42 FUNC GLOBAL DEFAULT 12 dlsym@@GLIBC_2.34
    35: 0000000000000000 0 FUNC GLOBAL DEFAULT UND pthread_create@GLIBC_2.17 (5)
  `), [[2, 14], [2, 17]]);
  assert.deepEqual(glibcRequirements('12: 0000000000000000 0 FUNC GLOBAL DEFAULT UND stat@GLIBC_2.33 (8)'), [[2, 33]]);
});
test('every shared runner job has an explicit timeout', () => {
  const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/release-tools.yml'), 'utf8');
  const jobs = workflow.split(/^  [a-z][a-z-]*:\s*$/m).slice(1).filter(s => /^    runs-on:/m.test(s));
  assert(jobs.length >= 4);
  for (const job of jobs) {
    const timeout = job.match(/^    timeout-minutes: (\d+)$/m);
    assert(timeout && +timeout[1] > 0 && +timeout[1] <= 120, 'unbounded release job');
  }
});
test('assembly checks transferred bytes and produces a sorted manifest', t => {
  const dir = fixture(t);
  seal(dir, expected);
  assemble(dir, expected);
  assert.deepEqual(fs.readdirSync(dir).sort(), ['SHA256SUMS', ...expected]);
  assert.equal(fs.readFileSync(path.join(dir, 'SHA256SUMS'), 'utf8'),
    expected.map(n => `${digest(path.join(dir, n))}  ${n}\n`).join(''));
});
for (const [name, mutate] of [
  ['missing payload', d => fs.unlinkSync(path.join(d, expected[0]))],
  ['unexpected payload', d => fs.writeFileSync(path.join(d, 'debug.zip'), 'debug')],
  ['corrupted payload', d => fs.appendFileSync(path.join(d, expected[0]), 'changed')],
  ['missing checksum', d => fs.unlinkSync(path.join(d, expected[0] + '.sha256'))],
  ['unexpected checksum', d => fs.writeFileSync(path.join(d, 'debug.sha256'), 'oops')],
  ['empty payload', d => fs.writeFileSync(path.join(d, expected[0]), '')],
  ['symlink payload', d => { fs.unlinkSync(path.join(d, expected[0])); fs.symlinkSync(expected[1], path.join(d, expected[0])); }],
]) test(`rejects ${name} before assembly`, t => {
  const dir = fixture(t);
  seal(dir, expected);
  mutate(dir);
  assert.throws(() => assemble(dir, expected));
  assert(!fs.existsSync(path.join(dir, 'SHA256SUMS')));
});
test('the target matrix has unique, safe asset names and an authoritative version', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, '.github'));
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.0\n');
  const spec = {product: 'example', versionFile: 'version.txt', targets: [
    {id: 'linux-x86_64', runner: ['self-hosted', 'linux', 'x64'], assets: ['{product}-{version}.tar.gz']},
  ]};
  const write = () => fs.writeFileSync(path.join(root, '.github/release.json'), JSON.stringify(spec));
  write();
  assert.deepEqual(plan(root).expected, ['example-0.1.0.tar.gz']);
  spec.targets.push(spec.targets[0]); write();
  assert.throws(() => plan(root), /duplicate/);
  spec.targets.pop(); spec.targets[0].assets = ['../escape']; write();
  assert.throws(() => plan(root), /unsafe/);
});
test('MSI verification is derived from assets and cannot be disabled in metadata', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, '.github'));
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.0\n');
  const spec = {product: 'example', versionFile: 'version.txt', hasMsi: false, targets: [
    {id: 'windows-x86_64', runner: ['self-hosted', 'windows', 'x64'], assets: ['example.msi', 'example.zip']},
  ]};
  const write = () => fs.writeFileSync(path.join(root, '.github/release.json'), JSON.stringify(spec));
  write();
  assert.equal(plan(root).hasMsi, true);
  spec.targets[0].id = 'linux-x86_64'; write();
  assert.throws(() => plan(root), /MSI requires a Windows target/);
  spec.targets[0].assets = ['example.tar.gz']; write();
  assert.equal(plan(root).hasMsi, false);
});
test('unsigned publication requires an exception for the exact source version', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, '.github'));
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.0\n');
  const spec = {product: 'example', versionFile: 'version.txt', targets: [
    {id: 'linux-x86_64', runner: ['self-hosted', 'linux', 'x64'], assets: ['example.tar.gz']},
  ]};
  const write = () => fs.writeFileSync(path.join(root, '.github/release.json'), JSON.stringify(spec));
  write();
  assert.equal(plan(root).unsignedRelease, false);
  spec.unsignedReleaseVersion = '0.1.0'; write();
  assert.equal(plan(root).unsignedRelease, true);
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.1\n');
  assert.throws(() => plan(root), /exception does not cover this version/);
});
test('legacy routing is limited to the documented Linux ARM64 scale set', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, '.github'));
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.0\n');
  const target = {id: 'linux-aarch64', runner: 'eph-linux-arm64', assets: ['example.tar.gz']};
  const spec = {product: 'example', versionFile: 'version.txt', targets: [target]};
  const write = () => fs.writeFileSync(path.join(root, '.github/release.json'), JSON.stringify(spec));
  write();
  assert.throws(() => plan(root), /routing needs a reason/);
  target.runnerReason = 'Tart pool is deferred; use the live scale set'; write();
  assert.equal(plan(root).matrix[0].runner, 'eph-linux-arm64');
  target.runner = 'ubuntu-latest'; write();
  assert.throws(() => plan(root), /self-hosted runner required/);
  target.runner = 'ubuntu-24.04-arm'; write();
  assert.throws(() => plan(root), /version-scoped migration/);
  target.runnerMigration = {version: '0.1.0', owner: 'zah',
    followup: 'https://github.com/metacraft-labs/metacraft-specs/blob/latest/issues/2026-09-28-release-linux-arm64-runner-migration.md'};
  write();
  assert.equal(plan(root).matrix[0].runner, 'ubuntu-24.04-arm');
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.1\n');
  assert.throws(() => plan(root), /version-scoped migration/);
});
test('the dedicated release lane accepts only Linux x64 and its exact scale-set name', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, '.github'));
  fs.writeFileSync(path.join(root, 'version.txt'), '0.1.0\n');
  const target = {id: 'linux-x86_64', runner: 'eph-linux-x64-release', assets: ['example.tar.gz']};
  const spec = {product: 'example', versionFile: 'version.txt', targets: [target]};
  const write = () => fs.writeFileSync(path.join(root, '.github/release.json'), JSON.stringify(spec));
  write();
  assert.equal(plan(root).matrix[0].runner, 'eph-linux-x64-release');
  target.id = 'linux-aarch64'; write();
  assert.throws(() => plan(root), /self-hosted runner required/);
  target.id = 'linux-x86_64'; target.runner = 'eph-linux-x64-release-typo'; write();
  assert.throws(() => plan(root), /self-hosted runner required/);
});
