// Real action launcher, Bash parser, filesystem and Git boundary tests.
// Minimal PATH entries are symlinks to real executables, not tool doubles.
// Permission failures use chmod on real directories/files. Two deterministic
// fault controls need injection: a Git wrapper fails after real ls-remote
// output, and a Node preload fails after reading a real workflow prefix.
// Reliably causing those late I/O failures otherwise requires races or a faulty
// filesystem/transport. Neither replaces the real permission/error controls.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const owner = path.resolve(__dirname, "..");
const actionDirectory = path.join(owner, "assert-workflow-triggers");
const metadata = fs.readFileSync(
  path.join(actionDirectory, "action.yml"),
  "utf8",
);
assert.match(metadata, /^  using: node24$/m);
const main = metadata.match(/^  main: (.+)$/m)?.[1];
assert.ok(main, "action metadata must select its actual launcher");
const launcher = path.join(actionDirectory, main);
const guard = path.join(__dirname, "assert-workflow-triggers-mainline.sh");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "workflow-action-"));
after(() => fs.rmSync(temporary, { recursive: true, force: true }));
const minimalPath = path.join(temporary, "bin");
fs.mkdirSync(minimalPath);
const tools = {};
for (const name of ["bash", "git"]) {
  const executable = execFileSync(
    "bash",
    ["-c", 'command -v "$1"', "resolve", name],
    {
      encoding: "utf8",
    },
  ).trim();
  tools[name] = fs.realpathSync(executable);
}
fs.symlinkSync(tools.bash, path.join(minimalPath, "bash"));
const detectionPath = path.join(temporary, "detection-bin");
fs.mkdirSync(detectionPath);
for (const name of ["bash", "git"]) {
  fs.symlinkSync(tools[name], path.join(detectionPath, name));
}

function environment(extra = {}) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (
      key.startsWith("GIT_") ||
      key.startsWith("WORKFLOW_") ||
      key.startsWith("INPUT_")
    ) {
      delete env[key];
    }
  }
  return {
    ...env,
    PATH: minimalPath,
    LC_ALL: "C",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: os.devNull,
    ...extra,
  };
}

function project() {
  const root = fs.mkdtempSync(path.join(temporary, "project-"));
  fs.mkdirSync(path.join(root, ".github/workflows"), { recursive: true });
  return root;
}

function workflow(root, name, branch = "dev") {
  const filename = path.join(root, name);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(
    filename,
    `name: CI\non:\n  push:\n    branches: [${branch}]\n`,
  );
  return filename;
}

function action(
  root,
  inputs = {},
  extra = {},
  cwd = root,
  entrypoint = launcher,
) {
  const result = spawnSync(process.execPath, [entrypoint], {
    cwd,
    env: environment({
      GITHUB_WORKSPACE: root,
      INPUT_MAINLINE: "dev",
      INPUT_WORKFLOWS: "",
      ...inputs,
      ...extra,
    }),
    encoding: "utf8",
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

function verdict(result, code, pattern, stream = "stdout") {
  assert.equal(result.status, code, result.stdout + result.stderr);
  assert.match(result[stream], pattern);
}

test("actual declared launcher works with only Bash on PATH", () => {
  const availability = spawnSync(
    tools.bash,
    [
      "-c",
      'for tool in node find dirname sort grep sed head tr git; do command -v "$tool" && exit 99; done',
    ],
    {
      env: environment(),
      encoding: "utf8",
    },
  );
  assert.equal(availability.status, 1);
  assert.equal(availability.stdout, "");
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  workflow(root, ".github/workflows/check.yaml");
  verdict(
    action(
      root,
      {},
      {
        WORKFLOW_TRIGGERS_NODE: "/a/runtime/that/must/not/be/used",
        WORKFLOW_TRIGGERS_ROOT: "/a/workspace/that/must/not/be/used",
        GUARD_DIR: "/an/action/that/must/not/be/used",
      },
    ),
    0,
    /2 workflow\(s\)/,
  );
  assert.equal(action(root).stderr, "");
});

test("actual action preserves filter rejection status and stdout", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml", "stable");
  const result = action(root);
  verdict(result, 1, /does not name the mainline/);
  assert.equal(result.stderr, "");
});

test("mainline input overrides ambient mainline environment", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml", "product");
  verdict(
    action(
      root,
      { INPUT_MAINLINE: "product" },
      {
        WORKFLOW_MAINLINE_BRANCH: "dev",
      },
    ),
    0,
    /mainline `product`/,
  );
});

test("empty mainline input clears ambient value and discovers real origin refs", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  const origin = path.join(root, "origin.git");
  const git = (args, cwd = root) =>
    execFileSync(tools.git, args, {
      cwd,
      env: environment(),
      stdio: "pipe",
    });
  git(["init", "--quiet", "--bare", origin]);
  git([
    "--git-dir",
    origin,
    "fetch",
    "--quiet",
    "--depth=1",
    "--no-tags",
    owner,
    "HEAD:refs/heads/dev",
  ]);
  git(["init", "--quiet"]);
  git(["remote", "add", "origin", origin]);
  verdict(
    action(
      root,
      { INPUT_MAINLINE: "" },
      {
        WORKFLOW_MAINLINE_BRANCH: "stable",
        PATH: detectionPath,
      },
    ),
    0,
    /mainline `dev`/,
  );
});

test("direct CLI retains argument and environment mainline precedence", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/ci.yml");
  for (const [args, mainline] of [
    [["dev", file], "stable"],
    [[], "dev"],
  ]) {
    const result = spawnSync(tools.bash, [guard, ...args], {
      cwd: root,
      env: environment({
        WORKFLOW_MAINLINE_BRANCH: mainline,
        WORKFLOW_TRIGGERS_ROOT: root,
        WORKFLOW_TRIGGERS_NODE: process.execPath,
      }),
      encoding: "utf8",
    });
    verdict(result, 0, /mainline `dev`/);
  }
});

test("empty or whitespace-only workflows input performs default discovery", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  workflow(root, ".github/workflows/omitted.yaml", "stable");
  for (const value of ["", " \t\n "]) {
    verdict(action(root, { INPUT_WORKFLOWS: value }), 1, /omitted.yaml/);
  }
});

test("explicit file selection does not silently fall back to discovery", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  workflow(root, ".github/workflows/omitted.yaml", "stable");
  verdict(
    action(root, { INPUT_WORKFLOWS: ".github/workflows/ci.yml" }),
    0,
    /1 workflow\(s\)/,
  );
});

test("file-list whitespace splitting and glob expansion retain Bash semantics", () => {
  const root = project();
  workflow(root, "selected/one.yml");
  workflow(root, "selected/two.yaml");
  workflow(root, "selected/with space.yml");
  verdict(
    action(root, { INPUT_WORKFLOWS: "selected/one.yml\t\nselected/two.yaml" }),
    0,
    /2 workflow\(s\)/,
  );
  verdict(
    action(root, { INPUT_WORKFLOWS: "selected/*space*.yml" }),
    0,
    /1 workflow\(s\)/,
  );
});

test("workflow inputs are not evaluated as shell source", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  verdict(
    action(root, { INPUT_WORKFLOWS: "$(printf injected > injected)" }),
    2,
    /no such file/,
    "stderr",
  );
  assert.equal(fs.existsSync(path.join(root, "injected")), false);
  verdict(
    action(root, { INPUT_MAINLINE: "dev; printf injected > injected" }),
    1,
    /does not name the mainline/,
  );
  assert.equal(fs.existsSync(path.join(root, "injected")), false);
});

test("real launcher and caller checkouts may both have spaces in their paths", () => {
  const source = path.join(temporary, "action checkout with spaces");
  const root = path.join(temporary, "caller workspace with spaces");
  for (const file of [
    "assert-workflow-triggers/action.yml",
    "assert-workflow-triggers/index.cjs",
    ".github/assert-workflow-triggers-mainline.sh",
    ".github/enumerate-workflows.cjs",
    ".github/read-workflow.cjs",
  ]) {
    fs.mkdirSync(path.dirname(path.join(source, file)), { recursive: true });
    fs.copyFileSync(path.join(owner, file), path.join(source, file));
  }
  workflow(root, ".github/workflows/with space.yml");
  const entrypoint = path.join(source, "assert-workflow-triggers", main);
  verdict(action(root, {}, {}, root, entrypoint), 0, /1 workflow\(s\)/);
  verdict(
    action(
      root,
      { INPUT_WORKFLOWS: ".github/workflows/*space*.yml" },
      {},
      root,
      entrypoint,
    ),
    0,
    /1 workflow\(s\)/,
  );
});

test("default discovery uses caller workspace, not action checkout or process cwd", () => {
  const root = project();
  const elsewhere = project();
  workflow(root, ".github/workflows/ci.yml");
  workflow(elsewhere, ".github/workflows/bad.yml", "stable");
  verdict(action(root, {}, {}, elsewhere), 0, /1 workflow\(s\)/);
});

test("explicit relative globs expand in the original caller working directory", () => {
  const root = project();
  const cwd = project();
  workflow(root, ".github/workflows/bad.yml", "stable");
  workflow(cwd, "selected/good.yml");
  verdict(
    action(root, { INPUT_WORKFLOWS: "selected/*.yml" }, {}, cwd),
    0,
    /1 workflow\(s\)/,
  );
});

test("empty discovery and missing explicit files remain status 2 errors", () => {
  const root = project();
  verdict(action(root), 2, /no workflow files found/, "stderr");
  verdict(
    action(root, { INPUT_WORKFLOWS: "missing.yml" }),
    2,
    /no such file/,
    "stderr",
  );
});

test("actual action retains real unreadable-directory diagnostics and status", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  const directory = path.join(root, ".github/workflows");
  verdict(action(root), 0, /1 workflow\(s\)/);
  fs.chmodSync(directory, 0);
  try {
    const result = action(root);
    verdict(result, 2, /EACCES/, "stderr");
    assert.match(
      result.stderr,
      /could not enumerate workflow files.*\(exit 1\)/,
    );
    assert.equal(result.stdout, "");
  } finally {
    fs.chmodSync(directory, 0o700);
  }
});

test("discovery includes both suffixes and dotfiles, but not nested workflows", () => {
  const root = project();
  workflow(root, ".github/workflows/.hidden.yml");
  workflow(root, ".github/workflows/ci.yaml");
  workflow(root, ".github/workflows/nested/bad.yml", "stable");
  workflow(root, ".github/workflows/ignored.txt", "stable");
  verdict(action(root), 0, /2 workflow\(s\)/);
});

test("matching directory and broken symlink names reach the scanner's file refusal", () => {
  const root = project();
  fs.mkdirSync(path.join(root, ".github/workflows/directory.yml"));
  verdict(action(root), 2, /no such file.*directory.yml/, "stderr");
  fs.rmdirSync(path.join(root, ".github/workflows/directory.yml"));
  fs.symlinkSync("missing", path.join(root, ".github/workflows/broken.yaml"));
  verdict(action(root), 2, /no such file.*broken.yaml/, "stderr");
});

test("workflow file symlinks remain accepted without following directory roots", () => {
  const root = project();
  const file = workflow(root, "selected/good.yml");
  fs.symlinkSync(file, path.join(root, ".github/workflows/link.yml"));
  verdict(action(root), 0, /1 workflow\(s\)/);
  const other = project();
  fs.rmdirSync(path.join(other, ".github/workflows"));
  fs.symlinkSync(
    path.join(root, ".github/workflows"),
    path.join(other, ".github/workflows"),
  );
  verdict(action(other), 2, /no workflow files found/, "stderr");
});

test("missing Bash remains a nonzero launch error, without runtime fallback", () => {
  verdict(action(project(), {}, { PATH: "" }), 127, /ENOENT/, "stderr");
});

test("empty exemption cannot pass a valid filter under the minimal runtime", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/ci.yml");
  verdict(action(root), 0, /1 workflow\(s\)/);
  // No final newline and horizontal whitespace exercise the actual marker
  // matching boundary without making the otherwise valid filter reject it.
  fs.appendFileSync(file, "\t# ci-mainline-exempt: \t");
  for (const inputs of [{}, { INPUT_WORKFLOWS: file }]) {
    const result = action(root, inputs);
    verdict(result, 1, /with no reason/);
    assert.equal(result.stderr, "");
    assert.doesNotMatch(result.stdout, /workflow\(s\) name/);
  }
});

test("legitimate exemption retains its reason under the minimal runtime", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/deploy.yml", "cloud");
  verdict(action(root), 1, /does not name the mainline/);
  fs.appendFileSync(file, "  # ci-mainline-exempt: deploys `cloud` only\n");
  for (const inputs of [{}, { INPUT_WORKFLOWS: file }]) {
    const result = action(root, inputs);
    verdict(result, 0, /skip .*deploy.yml: exempt — deploys `cloud` only/);
    assert.match(result.stdout, /1 workflow\(s\)/);
    assert.equal(result.stderr, "");
  }
});

test("multiple exemption markers retain any-reason precedence and first reason text", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/deploy.yml", "cloud");
  fs.appendFileSync(
    file,
    "# ci-mainline-exempt: \n# ci-mainline-exempt: deploy\n",
  );
  verdict(action(root), 0, /skip .*: exempt — \n/);
  fs.writeFileSync(
    file,
    "# ci-mainline-exempt: first\n# ci-mainline-exempt: \n",
  );
  verdict(action(root), 0, /skip .*: exempt — first\n/);
});

test("real unreadable workflow refuses both discovery and explicit-file checking", () => {
  const root = project();
  workflow(root, ".github/workflows/a-valid.yml");
  const file = workflow(root, ".github/workflows/z-unreadable.yml");
  fs.appendFileSync(file, "# ci-mainline-exempt: \n");
  verdict(action(root), 1, /with no reason/);
  fs.chmodSync(file, 0);
  try {
    // A privileged process/filesystem that ignores chmod fails setup, never
    // reports this permission test as a skipped or passing case.
    assert.throws(() => fs.readFileSync(file), { code: "EACCES" });
    for (const inputs of [{}, { INPUT_WORKFLOWS: file }]) {
      const result = action(root, inputs);
      verdict(result, 2, /EACCES/, "stderr");
      assert.ok(result.stderr.includes(file));
      assert.match(result.stderr, /could not read workflow file.*\(exit 1\)/);
      assert.equal(result.stdout, "");
    }
  } finally {
    fs.chmodSync(file, 0o600);
  }
});

test("read failure after a valid prefix cannot hide an empty exemption", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/ci.yml");
  const prefixBytes = fs.statSync(file).size;
  fs.appendFileSync(file, "# ci-mainline-exempt:\n");
  verdict(action(root), 1, /with no reason/);
  const preload = path.join(root, "fail-late-read.cjs");
  fs.writeFileSync(
    preload,
    `const fs = require("node:fs");
const open = fs.openSync;
const read = fs.readSync;
let target;
let bytes = 0;
fs.openSync = function(filename, ...args) {
  const fd = open.call(this, filename, ...args);
  if (filename === process.env.FAIL_READ_FILE) target = fd;
  return fd;
};
fs.readSync = function(fd, buffer, offset, length, position) {
  if (fd !== target) return read.call(this, fd, buffer, offset, length, position);
  if (bytes) throw new Error("EIO: injected failure after reading " + bytes + " real workflow bytes");
  bytes = read.call(this, fd, buffer, offset,
    Math.min(length, Number(process.env.FAIL_READ_BYTES)), position);
  if (!bytes) throw new Error("fault fixture did not read a real prefix");
  return bytes;
};
`,
  );
  const result = action(
    root,
    {},
    {
      NODE_OPTIONS: `--require=${preload}`,
      FAIL_READ_FILE: file,
      FAIL_READ_BYTES: String(prefixBytes),
    },
  );
  verdict(result, 2, /could not read workflow file/, "stderr");
  assert.ok(
    result.stderr.includes(`after reading ${prefixBytes} real workflow bytes`),
  );
  assert.equal(result.stdout, "");
});

test("binary bytes that Bash cannot preserve are a file-read error", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/ci.yml");
  fs.appendFileSync(file, "# ci-mainline-exempt:\0\n");
  const result = action(root);
  verdict(result, 2, /workflow contains a NUL byte/, "stderr");
  assert.equal(result.stdout, "");
});

test("missing Git is a detection error and explicit mainline needs no Git", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  verdict(action(root), 0, /1 workflow\(s\)/);
  const result = action(root, { INPUT_MAINLINE: "" });
  verdict(result, 2, /git: command not found/, "stderr");
  assert.match(result.stderr, /could not list branches on origin \(exit 127\)/);
  assert.equal(result.stdout, "");
});

test("failed real origin lookup preserves Git's diagnostic", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  execFileSync(tools.git, ["init", "--quiet", root], { env: environment() });
  const result = action(root, { INPUT_MAINLINE: "" }, { PATH: detectionPath });
  verdict(result, 2, /fatal:/, "stderr");
  assert.match(result.stderr, /could not list branches on origin \(exit 128\)/);
  assert.equal(result.stdout, "");
});

test("real origin detection keeps dev/latest/live priority and refuses legacy-only refs", () => {
  const root = project();
  const origin = path.join(root, "origin.git");
  const git = (args) =>
    execFileSync(tools.git, args, {
      cwd: root,
      env: environment(),
      stdio: "pipe",
    });
  git(["init", "--quiet", "--bare", origin]);
  git([
    "--git-dir",
    origin,
    "fetch",
    "--quiet",
    "--depth=1",
    "--no-tags",
    owner,
    ...["dev", "latest", "live", "main"].map(
      (branch) => `HEAD:refs/heads/${branch}`,
    ),
  ]);
  git(["init", "--quiet"]);
  git(["remote", "add", "origin", origin]);
  for (const branch of ["dev", "latest", "live"]) {
    workflow(root, ".github/workflows/ci.yml", branch);
    verdict(
      action(root, { INPUT_MAINLINE: "" }, { PATH: detectionPath }),
      0,
      new RegExp(`mainline \`${branch}\``),
    );
    git(["--git-dir", origin, "update-ref", "-d", `refs/heads/${branch}`]);
  }
  const result = action(root, { INPUT_MAINLINE: "" }, { PATH: detectionPath });
  verdict(result, 2, /no dev\/latest\/live branch on origin/, "stderr");
  assert.equal(result.stdout, "");
});

test("failed Git listing cannot accept a real mainline from partial output", () => {
  const root = project();
  workflow(root, ".github/workflows/ci.yml");
  const origin = path.join(root, "origin.git");
  const git = (args) =>
    execFileSync(tools.git, args, {
      cwd: root,
      env: environment(),
      stdio: "pipe",
    });
  git(["init", "--quiet", "--bare", origin]);
  git([
    "--git-dir",
    origin,
    "fetch",
    "--quiet",
    "--depth=1",
    "--no-tags",
    owner,
    "HEAD:refs/heads/dev",
  ]);
  git(["init", "--quiet"]);
  git(["remote", "add", "origin", origin]);
  verdict(
    action(root, { INPUT_MAINLINE: "" }, { PATH: detectionPath }),
    0,
    /mainline `dev`/,
  );
  const partialPath = path.join(root, "partial-bin");
  fs.mkdirSync(partialPath);
  fs.symlinkSync(tools.bash, path.join(partialPath, "bash"));
  fs.writeFileSync(
    path.join(partialPath, "git"),
    `#!${tools.bash}
"$REAL_GIT" "$@" || exit "$?"
echo 'injected Git failure after real refs' >&2
exit 23
`,
    { mode: 0o755 },
  );
  const result = action(
    root,
    { INPUT_MAINLINE: "" },
    { PATH: partialPath, REAL_GIT: tools.git },
  );
  verdict(result, 2, /injected Git failure after real refs/, "stderr");
  assert.match(result.stderr, /could not list branches on origin \(exit 23\)/);
  assert.equal(result.stdout, "");
});

test("invalid caller root cannot succeed using an explicit valid workflow", () => {
  const root = project();
  const file = workflow(root, ".github/workflows/ci.yml");
  const result = action(
    root,
    { INPUT_WORKFLOWS: file },
    { GITHUB_WORKSPACE: path.join(root, "absent") },
  );
  verdict(result, 2, /absent/, "stderr");
  assert.equal(result.stdout, "");
});

test("filesystem helpers are importable and return complete ordered data", () => {
  const root = project();
  const last = workflow(root, ".github/workflows/z.yml");
  const first = workflow(root, ".github/workflows/a.yaml");
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `
const assert = require("node:assert/strict");
const { enumerateWorkflows } = require(process.argv[1]);
const { readWorkflow } = require(process.argv[2]);
assert.deepEqual(enumerateWorkflows(process.argv[3]), [process.argv[4], process.argv[5]]);
assert.ok(readWorkflow(process.argv[4]).equals(require("node:fs").readFileSync(process.argv[4])));
`,
      path.join(__dirname, "enumerate-workflows.cjs"),
      path.join(__dirname, "read-workflow.cjs"),
      path.join(root, ".github/workflows"),
      first,
      last,
    ],
    {
      env: environment(),
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");
});
