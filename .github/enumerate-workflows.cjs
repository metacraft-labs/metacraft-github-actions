// One-level filesystem discovery for both the action and direct Bash CLI.
// Buffer the complete enumeration and close the directory before publishing
// any filenames: a failed read must never leave an accepted partial listing.
const fs = require("node:fs");
const path = require("node:path");

function enumerateWorkflows(directory) {
  // Like find without -L, do not descend through a symlink at the root.
  if (!fs.lstatSync(directory).isDirectory()) return [];
  const handle = fs.opendirSync(directory);
  const filenames = [];
  try {
    let entry;
    while ((entry = handle.readSync()) !== null) {
      if (entry.name.endsWith(".yml") || entry.name.endsWith(".yaml")) {
        const filename = path.join(directory, entry.name);
        if (!filename.includes(`${path.sep}.git${path.sep}`)) {
          // Match names, not file types; the existing scanner owns its -f
          // refusal, including broken symlinks and directories ending in .yml.
          filenames.push(
            process.platform === "win32"
              ? filename.replaceAll("\\", "/")
              : filename,
          );
        }
      }
    }
  } finally {
    handle.closeSync();
  }
  // Own the ordering as well as discovery; the caller needs no ambient sort.
  return filenames.sort((a, b) =>
    Buffer.compare(Buffer.from(a), Buffer.from(b)),
  );
}

module.exports = { enumerateWorkflows };

if (require.main === module) {
  try {
    if (process.argv.length !== 3)
      throw new Error("expected one workflow directory");
    const filenames = enumerateWorkflows(process.argv[2]);
    if (filenames.length) process.stdout.write(`${filenames.join("\n")}\n`);
  } catch (error) {
    // Some Node opendir errors omit their path; keep the failing directory
    // beside the original OS diagnostic rather than losing that context.
    process.stderr.write(
      `enumerate-workflows: ${process.argv[2] || "<missing directory>"}: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
