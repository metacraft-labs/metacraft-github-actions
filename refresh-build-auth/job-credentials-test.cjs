// Contract suite for the job-scoped Nix credential files and their broker.
//
// Real boundaries wherever one exists on a stock runner:
//   * the real Nix configuration parser (`nix config show --json`) reads the
//     files the module writes, through `!include` in NIX_CONFIG and through
//     the user nix.conf setup-nix writes -- isolated from the operator's own
//     configuration by NIX_CONF_DIR/HOME/XDG overrides;
//   * setup-nix's actual "Configure Nix authentication" step body is executed
//     with bash, not a paraphrase of it;
//   * real RSA keys and node:crypto sign/verify the App JWT.
//
// ONE MOCK, justified: GitHub's App endpoints are served by a loopback HTTP
// server. Minting a real installation token needs the production App's private
// key, which a test must never hold, and GitHub cannot be asked to trust a test
// key. The stand-in verifies the JWT with the test key's PUBLIC half and checks
// the request shapes the real API requires (method, path, Bearer scheme,
// API version header, `permissions` body), so a client that GitHub would
// reject is rejected here too. Expiry is driven by an injected clock: waiting
// out a real hour is not a test.
//
// Every credential below is an inert sentinel; nothing reaches the network.
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const crypto = require("node:crypto");
const { spawnSync, execFileSync } = require("node:child_process");

const jc = require("./job-credentials.cjs");

const repo = path.resolve(__dirname, "..");
const NIX = (() => {
  const found = spawnSync("sh", ["-c", "command -v nix"], { encoding: "utf8" });
  return found.status === 0 ? found.stdout.trim() : "";
})();

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "job-cred-test-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function privateDir(root) {
  return jc.createCredentialsDir(root);
}

// An environment in which Nix reads ONLY what the test gives it.
function isolatedNixEnv(home, extra = {}) {
  const empty = path.join(home, "empty.conf");
  if (!fs.existsSync(empty)) fs.writeFileSync(empty, "");
  return {
    PATH: process.env.PATH,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    XDG_CONFIG_DIRS: path.join(home, "no-xdg-dirs"),
    NIX_CONF_DIR: path.join(home, "no-system-conf"),
    NIX_USER_CONF_FILES: empty,
    ...extra,
  };
}

function effectiveTokens(env) {
  assert.ok(
    NIX,
    "the owning environment must provide Nix for real parser controls",
  );
  const out = execFileSync(
    NIX,
    ["--extra-experimental-features", "nix-command", "show-config", "--json"],
    { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  return JSON.parse(out)["access-tokens"].value;
}

function effectiveSetting(env, name) {
  const out = execFileSync(
    NIX,
    ["--extra-experimental-features", "nix-command", "show-config", "--json"],
    { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  return JSON.parse(out)[name].value;
}

test("token file round-trips and GitHub rotation keeps other hosts and owners", (t) => {
  const dir = privateDir(tempDir(t));
  jc.writeAccessTokens(dir, {
    "github.com": "old",
    "github.com/metacraft-labs": "old-owner",
    "github.com/partner": "partner",
    "gitlab.com": "gl",
  });
  jc.rotate(dir, "new", ["metacraft-labs"]);
  assert.deepEqual(jc.readAccessTokens(dir), {
    "github.com": "new",
    "github.com/metacraft-labs": "new",
    "github.com/partner": "partner",
    "gitlab.com": "gl",
  });
  assert.equal(fs.statSync(path.join(dir, jc.NIX_TOKENS)).mode & 0o777, 0o600);
  assert.throws(() => jc.rotate(dir, "", ["metacraft-labs"]));
  assert.throws(() => jc.rotate(dir, "has space", ["metacraft-labs"]));
});

test("netrc rotation replaces only the github.com machine", (t) => {
  const dir = privateDir(tempDir(t));
  fs.writeFileSync(
    path.join(dir, jc.NETRC),
    "machine github.com login x-access-token password old\nmachine cache.example.com password attic-sentinel\n",
    { mode: 0o600 },
  );
  jc.rotate(dir, "new", []);
  assert.equal(
    fs.readFileSync(path.join(dir, jc.NETRC), "utf8"),
    "machine github.com login x-access-token password new\nmachine cache.example.com password attic-sentinel\n",
  );
});

test("the credential directory is refused when it is shared or relative", (t) => {
  const root = tempDir(t);
  assert.throws(() =>
    jc.credentialsDir({ MCL_JOB_CREDENTIALS_DIR: "relative/dir" }),
  );
  const open = path.join(root, "open");
  fs.mkdirSync(open, { mode: 0o755 });
  fs.chmodSync(open, 0o755);
  assert.throws(
    () => jc.credentialsDir({ MCL_JOB_CREDENTIALS_DIR: open }),
    /group\/world/,
  );
  const good = privateDir(root);
  assert.equal(jc.credentialsDir({ MCL_JOB_CREDENTIALS_DIR: good }), good);
  assert.equal(jc.credentialsDir({}), "");
});

test("real Nix reads the token through the NIX_CONFIG include, follows a rotation, and degrades to none", (t) => {
  const home = tempDir(t);
  const dir = privateDir(home);
  jc.writeAccessTokens(dir, {
    "github.com": "first-sentinel",
    "gitlab.com": "kept-sentinel",
  });
  const env = isolatedNixEnv(home, {
    NIX_CONFIG: "http-connections = 7\n" + jc.includeLine(dir) + "\n",
  });
  assert.deepEqual(effectiveTokens(env), {
    "github.com": "first-sentinel",
    "gitlab.com": "kept-sentinel",
  });
  jc.rotate(dir, "second-sentinel", ["metacraft-labs"]);
  // Same environment -- exactly what a step or daemon started before the
  // refresh holds -- and the next nix process sees the new token.
  assert.deepEqual(effectiveTokens(env), {
    "github.com": "second-sentinel",
    "gitlab.com": "kept-sentinel",
  });
  // The runner empties RUNNER_TEMP between jobs: no credential, and no error.
  fs.rmSync(dir, { recursive: true });
  assert.deepEqual(effectiveTokens(env), {});
  assert.ok(jc.isIncludeLine(jc.includeLine(dir)));
  assert.ok(!jc.isIncludeLine("!include /etc/nix/other.conf"));
});

test("nix-auth refreshNix writes the file and leaves only an include in NIX_CONFIG", (t) => {
  const home = tempDir(t);
  const runnerTemp = path.join(home, "runner-temp");
  fs.mkdirSync(runnerTemp);
  const jobEnv = path.join(home, "github-env");
  fs.writeFileSync(jobEnv, "");
  const env = isolatedNixEnv(home, {
    NIX_CONFIG:
      "http-connections = 7\naccess-tokens = github.com=stale-sentinel gitlab.com=kept-sentinel\n",
    GH_TOKEN: "fresh-sentinel",
    TOKEN_OWNERS: "metacraft-labs",
    GITHUB_ENV: jobEnv,
    RUNNER_TEMP: runnerTemp,
  });
  const run = spawnSync(
    process.execPath,
    [path.join(__dirname, "nix-auth.cjs")],
    { env, encoding: "utf8" },
  );
  assert.equal(run.status, 0, run.stderr);
  const written = fs.readFileSync(jobEnv, "utf8");
  for (const secret of ["stale-sentinel", "fresh-sentinel", "kept-sentinel"])
    assert.ok(
      !written.includes(secret),
      "a token reached GITHUB_ENV: " + secret,
    );
  const dir = /^MCL_JOB_CREDENTIALS_DIR=(.*)$/m.exec(written)[1];
  const config = /NIX_CONFIG<<(\S+)\n([\s\S]*?)\n\1\n/.exec(written)[2];
  assert.equal(config, "http-connections = 7\n" + jc.includeLine(dir));
  const next = { ...env, NIX_CONFIG: config + "\n" };
  assert.deepEqual(effectiveTokens(next), {
    "github.com": "fresh-sentinel",
    "gitlab.com": "kept-sentinel",
  });
  // A second selection (refresh-build-auth) replaces the include, never stacks it.
  fs.writeFileSync(jobEnv, "");
  const again = spawnSync(
    process.execPath,
    [path.join(__dirname, "nix-auth.cjs")],
    {
      env: {
        ...next,
        GH_TOKEN: "fresher-sentinel",
        MCL_JOB_CREDENTIALS_DIR: dir,
      },
      encoding: "utf8",
    },
  );
  assert.equal(again.status, 0, again.stderr);
  const second = fs.readFileSync(jobEnv, "utf8");
  assert.ok(
    !second.includes("MCL_JOB_CREDENTIALS_DIR="),
    "an existing directory is reused",
  );
  const config2 = /NIX_CONFIG<<(\S+)\n([\s\S]*?)\n\1\n/.exec(second)[2];
  assert.equal(
    config2.split("\n").filter((l) => l.startsWith("!include")).length,
    1,
  );
  assert.deepEqual(effectiveTokens({ ...next, NIX_CONFIG: config2 + "\n" }), {
    "github.com": "fresher-sentinel",
    "gitlab.com": "kept-sentinel",
  });
});

test("setup-nix keeps every secret out of a persistent HOME", (t) => {
  const home = tempDir(t);
  const runnerTemp = path.join(home, "runner-temp");
  fs.mkdirSync(runnerTemp);
  const jobEnv = path.join(home, "github-env");
  fs.writeFileSync(jobEnv, "");
  // What an earlier job's setup-nix left behind on a persistent runner.
  fs.mkdirSync(path.join(home, ".config/nix"), { recursive: true });
  fs.writeFileSync(
    path.join(home, ".config/nix/netrc"),
    "machine github.com login x-access-token password leaked-sentinel\n",
  );
  const action = execFileSync(
    process.execPath,
    [
      path.join(repo, ".github/read-workflow.cjs"),
      path.join(repo, "setup-nix/action.yml"),
    ],
    {
      encoding: "utf8",
    },
  );
  const marker = "    - name: Configure Nix authentication\n";
  assert.equal(
    action.split(marker).length,
    2,
    "exactly one 'Configure Nix authentication' step",
  );
  const afterMarker = action.slice(action.indexOf(marker) + marker.length);
  const step = afterMarker.slice(
    0,
    (afterMarker.indexOf("\n    - name:") + 1 || afterMarker.length + 1) - 1,
  );
  const lines = step
    .slice(step.indexOf("run: |\n") + "run: |\n".length)
    .split("\n");
  const indent = lines[0].length - lines[0].trimStart().length;
  const body = [];
  for (const line of lines) {
    if (line.trim() && line.length - line.trimStart().length < indent) break;
    body.push(
      line.slice(Math.min(indent, line.length - line.trimStart().length)),
    );
  }
  const env = isolatedNixEnv(home, {
    NIX_USER_CONF_FILES: "",
    GH_TOKEN: "job-sentinel",
    GITHUB_ENV: jobEnv,
    RUNNER_TEMP: runnerTemp,
    GITHUB_ACTION_PATH: path.join(repo, "setup-nix"),
    EXTRA_SUBSTITUTERS: "",
    EXTRA_TRUSTED_PUBLIC_KEYS: "",
    ATTIC_TOKEN: "",
    ATTIC_ENDPOINT: "",
  });
  delete env.NIX_USER_CONF_FILES;
  const run = spawnSync("bash", ["-c", body.join("\n")], {
    env,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  const conf = fs.readFileSync(path.join(home, ".config/nix/nix.conf"), "utf8");
  assert.ok(
    !conf.includes("job-sentinel"),
    "the token was written into HOME nix.conf",
  );
  const netrc = path.join(home, ".config/nix/netrc");
  const dir = /^MCL_JOB_CREDENTIALS_DIR=(.*)$/m.exec(
    fs.readFileSync(jobEnv, "utf8"),
  )[1];
  // HOME keeps an empty regular file: no secret, and nothing that dangles
  // into a deleted directory for the next job's `touch` to trip over.
  assert.ok(fs.lstatSync(netrc).isFile(), "HOME netrc must be a regular file");
  assert.equal(fs.readFileSync(netrc, "utf8"), "");
  assert.deepEqual(effectiveTokens(env), { "github.com": "job-sentinel" });
  assert.equal(effectiveSetting(env, "netrc-file"), path.join(dir, jc.NETRC));
  assert.ok(
    fs
      .readFileSync(path.join(dir, jc.NETRC), "utf8")
      .includes("password job-sentinel"),
  );
  // The next job on this runner, before RUNNER_TEMP is reused: nothing stale.
  fs.rmSync(dir, { recursive: true });
  assert.deepEqual(effectiveTokens(env), {});
  assert.ok(
    !effectiveSetting(env, "netrc-file").startsWith(dir),
    "no setting may still name the deleted job directory",
  );
  // What devops-modules' setup-nix does next on the same runner.
  const touch = spawnSync("sh", [
    "-c",
    'touch "$1" && chmod 0600 "$1"',
    "sh",
    netrc,
  ]);
  assert.equal(touch.status, 0, "a later job must be able to touch HOME netrc");
});

function fakeGitHub(
  t,
  publicKey,
  { orgStatus = 200, mintStatus = 201, expiresInMs = 3600 * 1000 } = {},
) {
  const seen = [];
  let counter = 0;
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const auth = req.headers.authorization || "";
      const [h, p, s] = auth.replace(/^Bearer /, "").split(".");
      const valid =
        auth.startsWith("Bearer ") &&
        req.headers["x-github-api-version"] === "2022-11-28" &&
        crypto.verify(
          "RSA-SHA256",
          Buffer.from(h + "." + p),
          publicKey,
          Buffer.from(s || "", "base64url"),
        );
      const claims = valid
        ? JSON.parse(Buffer.from(p, "base64url").toString())
        : null;
      seen.push({ method: req.method, url: req.url, valid, claims, body });
      const reply = (status, json) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(json));
      };
      if (!valid)
        return reply(401, { message: "A JSON web token could not be decoded" });
      if (
        req.method === "GET" &&
        req.url === "/orgs/metacraft-labs/installation"
      )
        return orgStatus === 200
          ? reply(200, { id: 4242 })
          : reply(orgStatus, { message: "Not Found" });
      if (
        req.method === "GET" &&
        req.url === "/users/metacraft-labs/installation"
      )
        return reply(200, { id: 4242 });
      if (
        req.method === "POST" &&
        req.url === "/app/installations/4242/access_tokens"
      ) {
        if (mintStatus !== 201)
          return reply(mintStatus, { message: "fixture refusal" });
        counter += 1;
        return reply(201, {
          token: "ghs_minted_sentinel_" + counter,
          expires_at: new Date(Date.now() + expiresInMs).toISOString(),
        });
      }
      return reply(404, { message: "Not Found" });
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      t.after(() => server.close());
      resolve({ url: `http://127.0.0.1:${server.address().port}`, seen });
    });
  });
}

function keyPair() {
  return crypto.generateKeyPairSync("rsa", {
    modulusLength: 2048,
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
}

test("the App JWT carries the claims GitHub requires", () => {
  const { privateKey, publicKey } = keyPair();
  const jwt = jc.appJwt("12345", privateKey, 1_000_000);
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), {
    alg: "RS256",
    typ: "JWT",
  });
  assert.deepEqual(JSON.parse(Buffer.from(p, "base64url")), {
    iat: 999_940,
    exp: 1_000_540,
    iss: "12345",
  });
  assert.ok(
    crypto.verify(
      "RSA-SHA256",
      Buffer.from(h + "." + p),
      publicKey,
      Buffer.from(s, "base64url"),
    ),
  );
});

test("minting looks up the installation and asks for read-only contents", async (t) => {
  const { privateKey, publicKey } = keyPair();
  const gh = await fakeGitHub(t, publicKey, { orgStatus: 404 });
  const minted = await jc.mintInstallationToken({
    apiUrl: gh.url,
    appId: "12345",
    privateKey,
    owner: "metacraft-labs",
    permissions: { contents: "read" },
  });
  assert.equal(minted.token, "ghs_minted_sentinel_1");
  assert.deepEqual(
    gh.seen.map((r) => [r.method, r.url]),
    [
      ["GET", "/orgs/metacraft-labs/installation"],
      ["GET", "/users/metacraft-labs/installation"],
      ["POST", "/app/installations/4242/access_tokens"],
    ],
  );
  assert.deepEqual(JSON.parse(gh.seen[2].body), {
    permissions: { contents: "read" },
  });
  const { privateKey: wrongKey } = keyPair();
  await assert.rejects(
    jc.mintInstallationToken({
      apiUrl: gh.url,
      appId: "12345",
      privateKey: wrongKey,
      owner: "metacraft-labs",
    }),
    /HTTP 401/,
  );
});

test("the broker refreshes before expiry, retries a failed mint, and stops with its directory", async (t) => {
  const dir = privateDir(tempDir(t));
  jc.writeAccessTokens(dir, { "github.com": "initial" });
  let clock = 0;
  const hour = 3600 * 1000;
  const outcomes = ["fail", "ok", "ok"];
  const minted = [];
  const result = await jc.runBroker({
    dir,
    owners: ["metacraft-labs"],
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
    },
    mint: async () => {
      const outcome = outcomes.shift();
      if (outcome === undefined) {
        fs.rmSync(dir, { recursive: true }); // the runner emptied RUNNER_TEMP
        throw new Error("no more fixture tokens");
      }
      if (outcome === "fail") throw new Error("HTTP 502");
      minted.push(clock);
      return { token: "rotated-" + minted.length, expiresAt: clock + hour };
    },
    log: () => {},
  });
  assert.equal(result.rotations, 2);
  // Failed first attempt at t=0, retried 15 s later. The next mint is due 15
  // minutes before that token's expiry, capped at 40 minutes after the mint.
  assert.deepEqual(minted, [15 * 1000, 15 * 1000 + 40 * 60 * 1000]);
  assert.ok(!fs.existsSync(dir));
});

test("the broker never sleeps past a short-lived token or stays alive past its lifetime", async () => {
  assert.equal(jc.nextRefreshDelay(10 * 60 * 1000, 0), 60 * 1000);
  assert.equal(jc.nextRefreshDelay(10 * 3600 * 1000, 0), 40 * 60 * 1000);
  assert.equal(jc.retryDelay(1), 15 * 1000);
  assert.equal(jc.retryDelay(20), 5 * 60 * 1000);
});

test("startBroker mints once in the foreground, masks it, and leaves a detached refresher", async (t) => {
  const { privateKey, publicKey } = keyPair();
  const gh = await fakeGitHub(t, publicKey);
  const dir = privateDir(tempDir(t));
  jc.writeAccessTokens(dir, { "github.com": "gh-token-sentinel" });
  fs.writeFileSync(
    path.join(dir, jc.NETRC),
    "machine github.com login x-access-token password gh-token-sentinel\n",
    {
      mode: 0o600,
    },
  );
  // Run in a child so its stdout (the ::add-mask:: command) is observable.
  const script = `require(${JSON.stringify(path.join(__dirname, "job-credentials.cjs"))}).startBroker().catch(e => { console.error(e.message); process.exit(1); })`;
  // Asynchronously: the GitHub stand-in is served by THIS process.
  const run = await new Promise((resolve) => {
    const child = require("node:child_process").spawn(
      process.execPath,
      ["-e", script],
      {
        env: {
          PATH: process.env.PATH,
          MCL_JOB_CREDENTIALS_DIR: dir,
          APP_ID: "12345",
          APP_PRIVATE_KEY: privateKey,
          TOKEN_OWNERS: "metacraft-labs",
          GITHUB_API_URL: gh.url,
        },
      },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
  assert.equal(run.status, 0, run.stderr);
  assert.ok(run.stdout.includes("::add-mask::ghs_minted_sentinel_1\n"));
  assert.ok(
    !run.stdout
      .replace("::add-mask::ghs_minted_sentinel_1", "")
      .includes("ghs_minted_sentinel_1"),
  );
  assert.ok(!(run.stdout + run.stderr).includes("PRIVATE KEY"));
  assert.deepEqual(jc.readAccessTokens(dir), {
    "github.com": "ghs_minted_sentinel_1",
  });
  assert.ok(
    fs
      .readFileSync(path.join(dir, jc.NETRC), "utf8")
      .includes("password ghs_minted_sentinel_1"),
  );
  const pid = Number(fs.readFileSync(path.join(dir, "broker.pid"), "utf8"));
  assert.ok(pid > 0);
  // The detached child is alive and holds no key in its environment.
  if (process.platform === "linux") {
    const environ = fs.readFileSync(`/proc/${pid}/environ`, "utf8");
    assert.ok(
      !environ.includes("PRIVATE KEY"),
      "the App key must not be in the broker's environment",
    );
  }
  const brokerLog = () => fs.readFileSync(path.join(dir, "broker.log"), "utf8");
  await new Promise((r) => setTimeout(r, 1000));
  assert.doesNotThrow(
    () => process.kill(pid, 0),
    "the broker died at start: " + brokerLog(),
  );
  // Asking it to stop is honoured within one poll interval.
  fs.writeFileSync(path.join(dir, jc.STOP), "");
  const deadline = Date.now() + 45 * 1000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch {
      break;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  assert.throws(
    () => process.kill(pid, 0),
    "the broker did not exit after broker.stop",
  );
  assert.match(brokerLog(), /broker exiting \(stopped\) after 0 rotation\(s\)/);
  assert.ok(
    !brokerLog().includes("ghs_minted_sentinel"),
    "the broker log must not carry a token",
  );
});

test("a broker started before setup-nix creates the directory, and setup-nix reuses it", async (t) => {
  const { privateKey, publicKey } = keyPair();
  const gh = await fakeGitHub(t, publicKey);
  const home = tempDir(t);
  const runnerTemp = path.join(home, "runner-temp");
  fs.mkdirSync(runnerTemp);
  const jobEnv = path.join(home, "github-env");
  fs.writeFileSync(jobEnv, "");
  const script = `require(${JSON.stringify(path.join(__dirname, "job-credentials.cjs"))}).startBroker().catch(e => { console.error(e.message); process.exit(1); })`;
  const run = await new Promise((resolve) => {
    const child = require("node:child_process").spawn(
      process.execPath,
      ["-e", script],
      {
        env: {
          PATH: process.env.PATH,
          RUNNER_TEMP: runnerTemp,
          GITHUB_ENV: jobEnv,
          APP_ID: "12345",
          APP_PRIVATE_KEY: privateKey,
          TOKEN_OWNERS: "metacraft-labs",
          GITHUB_API_URL: gh.url,
        },
      },
    );
    let stderr = "";
    child.stderr.on("data", (c) => (stderr += c));
    child.on("close", (status) => resolve({ status, stderr }));
  });
  assert.equal(run.status, 0, run.stderr);
  const dir = /^MCL_JOB_CREDENTIALS_DIR=(.*)$/m.exec(
    fs.readFileSync(jobEnv, "utf8"),
  )[1];
  assert.equal(path.dirname(dir), runnerTemp);
  assert.deepEqual(jc.readAccessTokens(dir), {
    "github.com": "ghs_minted_sentinel_1",
  });
  const pid = Number(fs.readFileSync(path.join(dir, "broker.pid"), "utf8"));
  t.after(() => {
    try {
      process.kill(pid, "SIGTERM");
    } catch {}
  });
  // setup-nix's own step, handed the job environment the broker exported.
  const action = execFileSync(
    process.execPath,
    [
      path.join(repo, ".github/read-workflow.cjs"),
      path.join(repo, "setup-nix/action.yml"),
    ],
    {
      encoding: "utf8",
    },
  );
  const marker = "    - name: Configure Nix authentication\n";
  const afterMarker = action.slice(action.indexOf(marker) + marker.length);
  const step = afterMarker.slice(0, afterMarker.indexOf("\n    - name:"));
  const lines = step
    .slice(step.indexOf("run: |\n") + "run: |\n".length)
    .split("\n");
  const indent = lines[0].length - lines[0].trimStart().length;
  const body = [];
  for (const line of lines) {
    if (line.trim() && line.length - line.trimStart().length < indent) break;
    body.push(
      line.slice(Math.min(indent, line.length - line.trimStart().length)),
    );
  }
  const env = isolatedNixEnv(home, {
    GH_TOKEN: "job-sentinel",
    GITHUB_ENV: jobEnv,
    RUNNER_TEMP: runnerTemp,
    MCL_JOB_CREDENTIALS_DIR: dir,
    GITHUB_ACTION_PATH: path.join(repo, "setup-nix"),
    EXTRA_SUBSTITUTERS: "",
    EXTRA_TRUSTED_PUBLIC_KEYS: "",
    ATTIC_TOKEN: "",
    ATTIC_ENDPOINT: "",
  });
  delete env.NIX_USER_CONF_FILES;
  const setup = spawnSync("bash", ["-c", body.join("\n")], {
    env,
    encoding: "utf8",
  });
  assert.equal(setup.status, 0, setup.stdout + setup.stderr);
  const exported = [
    ...fs
      .readFileSync(jobEnv, "utf8")
      .matchAll(/^MCL_JOB_CREDENTIALS_DIR=(.*)$/gm),
  ].map((m) => m[1]);
  assert.deepEqual(
    exported,
    [dir, dir],
    "setup-nix must reuse the broker's directory",
  );
  assert.ok(
    fs
      .readFileSync(path.join(home, ".config/nix/nix.conf"), "utf8")
      .includes(jc.includeLine(dir)),
  );
  // The broker's next rotation reaches what Nix reads, netrc included.
  jc.rotate(dir, "ghs_rotated_sentinel", ["metacraft-labs"]);
  assert.deepEqual(effectiveTokens(env), {
    "github.com": "ghs_rotated_sentinel",
  });
  assert.equal(effectiveSetting(env, "netrc-file"), path.join(dir, jc.NETRC));
  assert.ok(
    fs
      .readFileSync(path.join(dir, jc.NETRC), "utf8")
      .includes("password ghs_rotated_sentinel"),
  );
});

// The setup-nix step body, extracted from the real action.yml.
function setupNixStepBody() {
  const action = execFileSync(
    process.execPath,
    [
      path.join(repo, ".github/read-workflow.cjs"),
      path.join(repo, "setup-nix/action.yml"),
    ],
    { encoding: "utf8" },
  );
  const marker = "    - name: Configure Nix authentication\n";
  const afterMarker = action.slice(action.indexOf(marker) + marker.length);
  const step = afterMarker.slice(0, afterMarker.indexOf("\n    - name:"));
  const lines = step
    .slice(step.indexOf("run: |\n") + "run: |\n".length)
    .split("\n");
  const indent = lines[0].length - lines[0].trimStart().length;
  const body = [];
  for (const line of lines) {
    if (line.trim() && line.length - line.trimStart().length < indent) break;
    body.push(
      line.slice(Math.min(indent, line.length - line.trimStart().length)),
    );
  }
  return body.join("\n");
}

function runSetupNix(t, { hostConf, attic }) {
  const home = tempDir(t);
  const runnerTemp = path.join(home, "runner-temp");
  fs.mkdirSync(runnerTemp);
  const jobEnv = path.join(home, "github-env");
  fs.writeFileSync(jobEnv, "");
  const systemDir = path.join(home, "system-conf");
  fs.mkdirSync(systemDir);
  const hostNetrc = path.join(systemDir, "netrc");
  fs.writeFileSync(
    hostNetrc,
    "machine cache.example.com password host-pull-sentinel\n",
  );
  fs.writeFileSync(
    path.join(systemDir, "nix.conf"),
    hostConf.replaceAll("@HOST_NETRC@", hostNetrc),
  );
  const env = isolatedNixEnv(home, {
    NIX_CONF_DIR: systemDir,
    GH_TOKEN: "job-sentinel",
    GITHUB_ENV: jobEnv,
    RUNNER_TEMP: runnerTemp,
    GITHUB_ACTION_PATH: path.join(repo, "setup-nix"),
    EXTRA_SUBSTITUTERS: "https://cache.example.com/private",
    EXTRA_TRUSTED_PUBLIC_KEYS: "private:AAAA",
    ATTIC_TOKEN: attic ? "job-attic-sentinel" : "",
    ATTIC_ENDPOINT: attic ? "https://cache.example.com/" : "",
  });
  delete env.NIX_USER_CONF_FILES;
  const run = spawnSync("bash", ["-c", setupNixStepBody()], {
    env,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  const dir = /^MCL_JOB_CREDENTIALS_DIR=(.*)$/m.exec(
    fs.readFileSync(jobEnv, "utf8"),
  )[1];
  return { env, dir, hostNetrc, stdout: run.stdout };
}

const HOST_CONF =
  "substituters = https://host.example/cache https://cache.nixos.org/\n" +
  "trusted-public-keys = host:BBBB cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n" +
  "netrc-file = @HOST_NETRC@\n";

test("setup-nix appends to the host's caches and keeps the host's netrc without an attic token", (t) => {
  const { env, dir, hostNetrc, stdout } = runSetupNix(t, {
    hostConf: HOST_CONF,
    attic: false,
  });
  const substituters = effectiveSetting(env, "substituters");
  assert.ok(
    substituters.includes("https://host.example/cache"),
    "host cache dropped: " + substituters,
  );
  assert.ok(substituters.includes("https://cache.example.com/private"));
  const keys = effectiveSetting(env, "trusted-public-keys");
  assert.ok(keys.includes("host:BBBB") && keys.includes("private:AAAA"));
  assert.equal(effectiveSetting(env, "netrc-file"), hostNetrc);
  assert.ok(!fs.existsSync(path.join(dir, jc.NETRC)));
  assert.ok(fs.existsSync(path.join(dir, "probe-netrc")));
  assert.match(stdout, /keeping the host's netrc-file/);
  assert.deepEqual(effectiveTokens(env), { "github.com": "job-sentinel" });
});

test("setup-nix uses the job netrc when the job brings the cache credential", (t) => {
  const { env, dir } = runSetupNix(t, { hostConf: HOST_CONF, attic: true });
  assert.equal(effectiveSetting(env, "netrc-file"), path.join(dir, jc.NETRC));
  assert.ok(
    fs
      .readFileSync(path.join(dir, jc.NETRC), "utf8")
      .includes("password job-attic-sentinel"),
  );
  assert.ok(
    effectiveSetting(env, "substituters").includes(
      "https://host.example/cache",
    ),
  );
});

// The 2026-11-12 incident, replayed (codetracer-trace-format PR #70, job
// 131107655430): a job's first setup-nix installed gh-token A, setup-dev-env's
// broker then minted B into the same directory, and a later setup-nix (the one
// setup-reprobuild runs to build repro) plus its selection step wrote A back
// over B. A expired an hour after it was minted, and the broker -- which
// schedules its next mint from B's expiry -- would not have repaired the file
// for another 18 minutes, so the next `nix` fetch answered 401. Once the
// broker owns the credential, no later writer may install an older token.
test("once the broker owns the GitHub credential, setup-nix and refreshNix keep its token", async (t) => {
  const { privateKey, publicKey } = keyPair();
  const gh = await fakeGitHub(t, publicKey);
  const home = tempDir(t);
  const runnerTemp = path.join(home, "runner-temp");
  fs.mkdirSync(runnerTemp);
  const jobEnv = path.join(home, "github-env");
  fs.writeFileSync(jobEnv, "");
  const stale = "gh-token-sentinel-A";
  const env = isolatedNixEnv(home, {
    GH_TOKEN: stale,
    TOKEN_OWNERS: "metacraft-labs",
    GITHUB_ENV: jobEnv,
    RUNNER_TEMP: runnerTemp,
    GITHUB_ACTION_PATH: path.join(repo, "setup-nix"),
    EXTRA_SUBSTITUTERS: "",
    EXTRA_TRUSTED_PUBLIC_KEYS: "",
    ATTIC_TOKEN: "",
    ATTIC_ENDPOINT: "",
  });
  delete env.NIX_USER_CONF_FILES;
  const setupNix = () => {
    const run = spawnSync("bash", ["-c", setupNixStepBody()], {
      env,
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    return run;
  };
  const selectNix = () => {
    const run = spawnSync(
      process.execPath,
      [path.join(__dirname, "nix-auth.cjs")],
      { env, encoding: "utf8" },
    );
    assert.equal(run.status, 0, run.stderr);
    return run;
  };
  const netrcOf = (dir) => fs.readFileSync(path.join(dir, jc.NETRC), "utf8");

  // 10:19 -- the workflow's own setup-nix, before any broker: A is installed.
  setupNix();
  const dir = /^MCL_JOB_CREDENTIALS_DIR=(.*)$/m.exec(
    fs.readFileSync(jobEnv, "utf8"),
  )[1];
  env.MCL_JOB_CREDENTIALS_DIR = dir;
  selectNix();
  assert.deepEqual(effectiveTokens(env), { "github.com": stale });

  // 10:56 -- setup-dev-env starts the broker in the same directory.
  const start = await new Promise((resolve) => {
    const child = require("node:child_process").spawn(
      process.execPath,
      [
        "-e",
        `require(${JSON.stringify(path.join(__dirname, "job-credentials.cjs"))}).startBroker().catch(e => { console.error(e.message); process.exit(1); })`,
      ],
      {
        env: {
          PATH: process.env.PATH,
          MCL_JOB_CREDENTIALS_DIR: dir,
          APP_ID: "12345",
          APP_PRIVATE_KEY: privateKey,
          TOKEN_OWNERS: "metacraft-labs",
          GITHUB_API_URL: gh.url,
        },
      },
    );
    let stderr = "";
    child.stderr.on("data", (c) => (stderr += c));
    child.on("close", (status) => resolve({ status, stderr }));
  });
  assert.equal(start.status, 0, start.stderr);
  const pid = Number(fs.readFileSync(path.join(dir, "broker.pid"), "utf8"));
  t.after(() => {
    try {
      process.kill(pid, "SIGTERM");
    } catch {}
  });
  const minted = "ghs_minted_sentinel_1";
  assert.deepEqual(effectiveTokens(env), { "github.com": minted });

  // 11:00 -- a second setup-nix and its selection step, both still handed A.
  const setup = setupNix();
  assert.deepEqual(
    effectiveTokens(env),
    { "github.com": minted },
    "setup-nix installed an older gh-token over the broker's token",
  );
  assert.match(setup.stdout, /credential broker owns/);
  const select = selectNix();
  assert.deepEqual(
    effectiveTokens(env),
    { "github.com": minted },
    "refreshNix installed an older gh-token over the broker's token",
  );
  const tokenFile = fs.readFileSync(path.join(dir, jc.NIX_TOKENS), "utf8");
  assert.ok(!tokenFile.includes(stale), "A reached the token file");
  assert.ok(netrcOf(dir).includes("password " + minted));
  assert.ok(!netrcOf(dir).includes(stale), "A reached the job netrc");
  // Both tokens are still registered with the runner, and neither is printed.
  for (const secret of [stale, minted])
    for (const run of [setup, select]) {
      assert.ok(run.stdout.includes("::add-mask::" + secret + "\n"));
      assert.ok(
        !run.stdout.replaceAll("::add-mask::" + secret, "").includes(secret),
      );
      assert.ok(!run.stderr.includes(secret));
    }

  // The broker's next rotation still reaches everything Nix reads.
  jc.rotate(dir, "ghs_rotated_sentinel", ["metacraft-labs"]);
  assert.deepEqual(effectiveTokens(env), {
    "github.com": "ghs_rotated_sentinel",
  });

  // Control: once the broker has been asked to stop it no longer owns the
  // credential, and the caller's token is installed as before.
  fs.writeFileSync(path.join(dir, jc.STOP), "");
  env.GH_TOKEN = "gh-token-sentinel-C";
  setupNix();
  selectNix();
  assert.deepEqual(effectiveTokens(env), {
    "github.com": "gh-token-sentinel-C",
  });
  assert.ok(netrcOf(dir).includes("password gh-token-sentinel-C"));
});

// A stand-in broker: an idle process whose argv ends the way the real one's
// does (`<node> <...>/job-credentials.cjs daemon`), which is what the procfs
// half of the ownership test looks for. Spawning the real daemon would need a
// GitHub App key and would rotate the file under the assertions.
function standInBroker(t) {
  const child = require("node:child_process").spawn(
    process.execPath,
    [
      "-e",
      "setInterval(() => {}, 1e9)",
      "/stand-in/job-credentials.cjs",
      "daemon",
    ],
    { stdio: "ignore" },
  );
  t.after(() => child.kill("SIGKILL"));
  return child.pid;
}

// The bash half of the ownership test, run on its own: setup-nix's step body
// up to (and including) the ownership function, then a probe of it.
function bashBrokerOwns(dir) {
  const body = setupNixStepBody();
  const end = body.indexOf("if broker_owns_token; then");
  assert.ok(end > 0, "setup-nix no longer defines broker_owns_token");
  const probe =
    body.slice(body.indexOf("tokens_file="), end) +
    "if broker_owns_token; then echo owned; else echo free; fi\n";
  const run = spawnSync(
    "bash",
    ["-c", 'set -euo pipefail\ncred_dir="$1"\n' + probe, "-", dir],
    {
      env: { PATH: process.env.PATH, GH_TOKEN: "given-sentinel" },
      encoding: "utf8",
    },
  );
  assert.equal(run.status, 0, run.stderr);
  return run.stdout.trim() === "owned";
}

test("only a live, unstopped broker owns the job's GitHub credential", async (t) => {
  const dir = privateDir(tempDir(t));
  jc.writeAccessTokens(dir, { "github.com": "broker-sentinel" });
  const pidFile = path.join(dir, "broker.pid");
  // Every case is asked of both the JS test and setup-nix's bash test, which
  // must agree: they guard the same file from two different writers.
  const owns = (expected, why) => {
    assert.equal(
      jc.brokerGithubToken(dir),
      expected ? "broker-sentinel" : "",
      "JS: " + why,
    );
    assert.equal(bashBrokerOwns(dir), expected, "bash: " + why);
  };
  owns(false, "no broker ever started here");
  const broker = standInBroker(t);
  fs.writeFileSync(pidFile, String(broker) + "\n");
  owns(true, "a live broker owns the credential");
  // A broker that has exited (pid of a child that has been reaped).
  const exited = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  fs.writeFileSync(pidFile, String(exited.pid) + "\n");
  owns(false, "an exited broker");
  for (const bad of ["not-a-pid", "0", "-1", "+1", "1 2", ""]) {
    fs.writeFileSync(pidFile, bad + "\n");
    owns(false, `a malformed pid file (${JSON.stringify(bad)})`);
  }
  if (fs.existsSync("/proc/self")) {
    // The broker died and its pid went to an unrelated live process: this
    // test runner stands in for it.
    fs.writeFileSync(pidFile, String(process.pid) + "\n");
    owns(false, "a reused pid naming some other process");
  }
  if (process.getuid && process.getuid() !== 0) {
    // pid 1 is alive but another user's: not a broker this job started.
    fs.writeFileSync(pidFile, "1\n");
    owns(false, "a pid owned by another user");
  }
  // A live broker that has been told to stop no longer owns it.
  fs.writeFileSync(pidFile, " " + String(broker) + "\n");
  owns(true, "surrounding whitespace in the pid file");
  fs.writeFileSync(path.join(dir, jc.STOP), "");
  owns(false, "a stopped broker");
  fs.rmSync(path.join(dir, jc.STOP));
  // A live broker whose file holds no GitHub token yet has nothing to defer to.
  jc.writeAccessTokens(dir, { "gitlab.com": "kept-sentinel" });
  assert.equal(jc.brokerGithubToken(dir), "");
});

// A runner's PATH need not carry sed, tr or cat: macOS mcl-bench-001 had no
// sed, and setup-nix failed with "sed: command not found" once a broker
// owned the credential. The ownership test and the token read must use bash
// builtins only, so run them with a PATH that holds bash and nothing else.
test("setup-nix reads the broker's token with bash builtins only", (t) => {
  const dir = privateDir(tempDir(t));
  jc.writeAccessTokens(dir, {
    "gitlab.com": "kept-sentinel",
    "github.com": "broker-sentinel",
  });
  fs.writeFileSync(
    path.join(dir, "broker.pid"),
    String(standInBroker(t)) + "\n",
  );
  const bashOnly = tempDir(t);
  const bash = spawnSync("bash", ["-c", "command -v bash"], {
    encoding: "utf8",
  }).stdout.trim();
  fs.symlinkSync(bash, path.join(bashOnly, "bash"));
  const body = setupNixStepBody();
  const start = body.indexOf("tokens_file=");
  const end = body.indexOf("\n\n", body.indexOf("if broker_owns_token; then"));
  assert.ok(start > 0 && end > start, "setup-nix's broker block moved");
  const run = spawnSync(
    path.join(bashOnly, "bash"),
    [
      "-c",
      // PATH is set inside the script as well: a host's shell startup can
      // put its system profile back on PATH (NixOS does), which would let a
      // sed or cat slip through unnoticed.
      'set -euo pipefail\nPATH="$2"\ncred_dir="$1"\n' +
        body.slice(start, end) +
        '\necho "token=$GH_TOKEN"\n',
      "-",
      dir,
      bashOnly,
    ],
    {
      env: { PATH: bashOnly, GH_TOKEN: "given-sentinel" },
      encoding: "utf8",
    },
  );
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /^token=broker-sentinel$/m);
  assert.equal(run.stderr, "");
});
