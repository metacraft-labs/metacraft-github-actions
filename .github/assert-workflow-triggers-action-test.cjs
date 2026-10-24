// Real action launcher, Bash parser, filesystem and Git boundary tests.
// Minimal PATH entries are symlinks to real executables, not tool doubles.
// Permission failures use chmod on a real directory; no filesystem is mocked.
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
for (const name of [
  "bash",
  "dirname",
  "sort",
  "grep",
  "sed",
  "head",
  "tr",
  "git",
]) {
  const executable = execFileSync(
    "bash",
    ["-c", 'command -v "$1"', "resolve", name],
    {
      encoding: "utf8",
    },
  ).trim();
  tools[name] = fs.realpathSync(executable);
  fs.symlinkSync(tools[name], path.join(minimalPath, name));
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

test("actual declared launcher works without ambient node or find", () => {
  const availability = spawnSync(
    tools.bash,
    ["-c", "command -v node; command -v find"],
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
