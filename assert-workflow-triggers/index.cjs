// The runner supplies this runtime even when its service PATH has no node.
// Hand its actual executable to discovery; never provision or guess one here.
const { spawnSync } = require("node:child_process");
const { constants } = require("node:os");

// Keep the former composite step's Bash splitting and pathname expansion.
// Inputs travel only through environment variables, never into shell source.
const result = spawnSync(
  "bash",
  [
    "--noprofile",
    "--norc",
    "-c",
    `set -uo pipefail
exec bash "$GUARD_DIR/../.github/assert-workflow-triggers-mainline.sh" \
  "$WORKFLOW_MAINLINE_BRANCH" $WORKFLOWS`,
  ],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      WORKFLOW_MAINLINE_BRANCH: process.env.INPUT_MAINLINE || "",
      WORKFLOWS: process.env.INPUT_WORKFLOWS || "",
      WORKFLOW_TRIGGERS_ROOT: process.env.GITHUB_WORKSPACE || "",
      GUARD_DIR: __dirname,
      WORKFLOW_TRIGGERS_NODE: process.execPath,
    },
  },
);

if (result.error) {
  process.stderr.write(`assert-workflow-triggers: ${result.error.message}\n`);
  process.exitCode = result.error.code === "ENOENT" ? 127 : 126;
} else if (result.signal) {
  process.exitCode = 128 + (constants.signals[result.signal] || 0);
} else {
  process.exitCode = result.status ?? 2;
}
