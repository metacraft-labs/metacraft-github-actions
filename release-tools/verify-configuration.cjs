// Real files installed in the disposable Linux package container; no mocks.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const [manifest, mode] = process.argv.slice(2);
assert(
  ["check", "mark", "preserved"].includes(mode),
  "unknown configuration check",
);
const entries = JSON.parse(fs.readFileSync(manifest));
const marker = Buffer.from("\n# operator edit: package preservation control\n");
for (const { destination, bytes } of entries) {
  const original = Buffer.from(bytes, "base64");
  const expected =
    mode === "preserved" ? Buffer.concat([original, marker]) : original;
  assert.deepEqual(fs.readFileSync(destination), expected, destination);
  const file = fs.statSync(destination);
  const directory = fs.statSync(path.dirname(destination));
  assert.equal(file.mode & 0o777, 0o644, destination);
  assert.equal(directory.mode & 0o777, 0o755, path.dirname(destination));
  assert.equal(file.uid, 0);
  assert.equal(file.gid, 0);
  assert.equal(directory.uid, 0);
  assert.equal(directory.gid, 0);
  if (mode === "mark") fs.appendFileSync(destination, marker);
}
console.log(`Configuration ${mode}: ${entries.length} canonical files`);
