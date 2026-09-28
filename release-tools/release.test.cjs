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
