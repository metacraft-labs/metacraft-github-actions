// Read a complete workflow before publishing any of it to the Bash scanner.
// Unlike a shell read loop, readFileSync distinguishes EOF from read errors.
const fs = require("node:fs");

function readWorkflow(filename) {
  const contents = fs.readFileSync(filename);
  // Bash variables cannot represent NUL; refuse rather than silently dropping
  // bytes from the file being checked. NUL is not valid YAML text either.
  if (contents.includes(0)) throw new Error("workflow contains a NUL byte");
  return contents;
}

module.exports = { readWorkflow };

if (require.main === module) {
  try {
    if (process.argv.length !== 3)
      throw new Error("expected one workflow file");
    process.stdout.write(readWorkflow(process.argv[2]));
  } catch (error) {
    process.stderr.write(
      `read-workflow: ${process.argv[2] || "<missing file>"}: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
