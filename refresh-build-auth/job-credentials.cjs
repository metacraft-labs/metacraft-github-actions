// Job-scoped Nix credential files, and the broker that keeps them fresh.
//
// WHY THIS EXISTS
// ---------------
// A CI Token Provider App installation token expires one hour after it is
// minted (https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
// setup-nix used to freeze that token into two places that outlive it:
//
//   * `$HOME/.config/nix/nix.conf` and `$HOME/.config/nix/netrc`. On the
//     persistent self-hosted runners HOME survives the job, so a LATER job that
//     runs `nix` without setting up its own credentials inherited this job's
//     token and failed with `HTTP error 401 ... "Bad credentials"` minutes after
//     it started (codetracer-launcher job 126423778474, 2026-11-04).
//   * `NIX_CONFIG` in `$GITHUB_ENV`, so every later step -- and every
//     long-lived process a step started, such as reprobuild's Nix evaluation
//     daemon -- carried a value that went stale an hour into the job
//     (codetracer launcher-recorder-e2e job 126423789105, 401 at minute 62).
//
// Now the secret material lives in a private directory under `$RUNNER_TEMP`
// (which the runner empties between jobs), Nix reaches it through an
// `!include` and a `netrc-file` symlink, and a token that must change is
// changed by rewriting those files in place. Nix reads its configuration when
// a `nix` process starts, so every process started after a rewrite sees the
// new token, including the ones a long-lived daemon spawns. Nix documents
// `!include` as "include, but ignore a missing file"
// (https://nix.dev/manual/nix/latest/command-ref/conf-file.html), which is
// exactly the behaviour wanted on a persistent runner once the directory is
// gone: no credential rather than a dead one.
//
// The broker (`daemon` below) re-mints the token from the App's private key
// before the current one expires. It is optional: without App credentials the
// files hold the caller's `gh-token` for its natural lifetime, as before.
//
// SECRETS
// -------
// Nothing here prints a token, a key or a JWT. A token the broker mints after
// its own step has ended cannot be registered with `::add-mask::` (the runner
// only reads workflow commands from a running step's stdout), so the broker
// requests those tokens with `contents: read` only: they are used for fetches,
// and a leaked one is worth an hour of read access and nothing more.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const NIX_TOKENS = "nix-access-tokens.conf";
const NETRC = "netrc";
const BROKER_LOG = "broker.log";
const BROKER_PID = "broker.pid";
const STOP = "broker.stop";
const DIR_PREFIX = "mcl-job-credentials.";

// Refresh this long before expiry, and never sleep longer than MAX_SLEEP_MS
// between mints, so a clock disagreement with GitHub cannot run a token out.
const REFRESH_MARGIN_MS = 15 * 60 * 1000;
const MAX_SLEEP_MS = 40 * 60 * 1000;
const MIN_SLEEP_MS = 60 * 1000;
// A runner job cannot outlive this on any runner class we use; the broker
// stops by itself even if nothing else stops it.
const DEFAULT_MAX_LIFETIME_MS = 26 * 60 * 60 * 1000;
const POLL_MS = 30 * 1000;

/** The job credential directory, validated, or "" when none is configured. */
function credentialsDir(env = process.env) {
  const dir = env.MCL_JOB_CREDENTIALS_DIR || "";
  if (!dir) return "";
  if (!path.isAbsolute(dir))
    throw new Error("MCL_JOB_CREDENTIALS_DIR must be an absolute path");
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw new Error("MCL_JOB_CREDENTIALS_DIR must be a real directory");
  if (process.platform !== "win32") {
    if (typeof process.getuid === "function" && stat.uid !== process.getuid())
      throw new Error("MCL_JOB_CREDENTIALS_DIR is not owned by this user");
    if ((stat.mode & 0o077) !== 0)
      throw new Error(
        "MCL_JOB_CREDENTIALS_DIR must not be group/world accessible",
      );
  }
  return dir;
}

/** Create a fresh private credential directory under `root` (RUNNER_TEMP). */
function createCredentialsDir(root) {
  if (!path.isAbsolute(root))
    throw new Error("the credential root must be an absolute path");
  const dir = fs.mkdtempSync(path.join(root, DIR_PREFIX));
  fs.chmodSync(dir, 0o700);
  if (/\s/.test(dir))
    throw new Error(
      "the job credential directory path contains whitespace, which nix.conf cannot express",
    );
  return dir;
}

/** The nix.conf line that reads this job's token file (absent file => ignored). */
function includeLine(dir) {
  if (/\s/.test(dir))
    throw new Error(
      "the job credential directory path contains whitespace, which nix.conf cannot express",
    );
  return "!include " + path.join(dir, NIX_TOKENS);
}

/** True for an `!include` of some job's token file, so a refresh replaces it. */
function isIncludeLine(line) {
  const match = /^\s*!include\s+(\S+)\s*$/.exec(line);
  return (
    match !== null &&
    path.basename(match[1]) === NIX_TOKENS &&
    path.basename(path.dirname(match[1])).startsWith(DIR_PREFIX)
  );
}

/** Replace `file` atomically: readers see the old or the new bytes, never half. */
function writeAtomic(file, content) {
  const temporary = `${file}.tmp.${process.pid}.${crypto.randomUUID()}`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, content, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, file);
}

/** Render a Nix `access-tokens` setting; hosts sorted for a stable file. */
function formatAccessTokens(tokens) {
  for (const [host, value] of Object.entries(tokens))
    if (/\s/.test(host) || /\s/.test(value))
      throw new Error("access-tokens entries cannot contain whitespace");
  const entries = Object.keys(tokens)
    .sort()
    .map((host) => host + "=" + tokens[host]);
  return "access-tokens = " + entries.join(" ") + "\n";
}

/** Parse the file this module writes (one `access-tokens = ...` line). */
function readAccessTokens(dir) {
  const file = path.join(dir, NIX_TOKENS);
  if (!fs.existsSync(file)) return {};
  const tokens = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const match = /^\s*access-tokens\s*=(.*)$/.exec(line);
    if (!match) continue;
    for (const entry of match[1].trim().split(/\s+/).filter(Boolean)) {
      const at = entry.indexOf("=");
      if (at <= 0)
        throw new Error("malformed access-tokens entry in job credentials");
      tokens[entry.slice(0, at)] = entry.slice(at + 1);
    }
  }
  return tokens;
}

/**
 * Write the include file: the token map, and -- only once setup-nix has put a
 * netrc in this directory -- a `netrc-file` pointing at it. The include is
 * read after the user nix.conf's own `netrc-file`, so it wins while the job
 * runs and vanishes with the directory, and $HOME never has to hold a
 * credential or a link that dangles into a deleted directory. Without a job
 * netrc no `netrc-file` is set, so a host-configured one is left alone.
 */
function writeAccessTokens(dir, tokens) {
  let content = formatAccessTokens(tokens);
  if (fs.existsSync(path.join(dir, NETRC))) content += netrcLine(dir) + "\n";
  writeAtomic(path.join(dir, NIX_TOKENS), content);
}

function netrcLine(dir) {
  return "netrc-file = " + path.join(dir, NETRC);
}

/**
 * Point GitHub's entries at `token`: `github.com` itself and the
 * `github.com/<owner>` prefixes of the owners the token was minted for.
 * Every other host and owner keeps its value.
 */
function withGithubToken(tokens, token, owners) {
  const next = { ...tokens, "github.com": token };
  for (const owner of owners) {
    const prefix = "github.com/" + owner;
    if (Object.hasOwn(next, prefix)) next[prefix] = token;
  }
  return next;
}

/**
 * Rewrite the `machine github.com` entry of the job netrc, keeping every other
 * machine (the private binary cache's) byte for byte.
 */
function rotateNetrc(dir, token) {
  const file = path.join(dir, NETRC);
  if (!fs.existsSync(file)) return false;
  const line = "machine github.com login x-access-token password " + token;
  const kept = fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l !== "" && !/^\s*machine\s+github\.com(\s|$)/.test(l));
  writeAtomic(file, [line, ...kept].join("\n") + "\n");
  return true;
}

/** Install `token` as the job's GitHub credential for Nix. */
function rotate(dir, token, owners) {
  if (!token || /\s/.test(token))
    throw new Error("refusing an empty or malformed token");
  writeAccessTokens(dir, withGithubToken(readAccessTokens(dir), token, owners));
  rotateNetrc(dir, token);
}

function base64url(data) {
  return Buffer.from(data).toString("base64url");
}

/**
 * The App JWT GitHub expects: RS256, `iss` = App ID, at most ten minutes of
 * validity, `iat` backdated a minute against clock drift
 * (https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app).
 */
function appJwt(appId, privateKey, nowSeconds = Math.floor(Date.now() / 1000)) {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({
      iat: nowSeconds - 60,
      exp: nowSeconds + 540,
      iss: String(appId),
    }),
  );
  const signature = crypto.sign(
    "RSA-SHA256",
    Buffer.from(header + "." + payload),
    privateKey,
  );
  return header + "." + payload + "." + base64url(signature);
}

async function githubRequest(method, url, jwt, body) {
  const response = await fetch(url, {
    method,
    headers: {
      accept: "application/vnd.github+json",
      authorization: "Bearer " + jwt,
      "user-agent": "metacraft-labs-job-credential-broker",
      "x-github-api-version": "2022-11-28",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60 * 1000),
  });
  let json = null;
  try {
    json = await response.json();
  } catch {
    json = null;
  }
  return { status: response.status, json };
}

/**
 * Mint an installation token for `owner`'s installation of the App.
 * Endpoints: GET /orgs/{org}/installation (falling back to /users/{user}/installation)
 * and POST /app/installations/{id}/access_tokens
 * (https://docs.github.com/en/rest/apps/apps).
 */
async function mintInstallationToken({
  apiUrl,
  appId,
  privateKey,
  owner,
  permissions,
}) {
  const api = (apiUrl || "https://api.github.com").replace(/\/+$/, "");
  const jwt = appJwt(appId, privateKey);
  let installation = await githubRequest(
    "GET",
    `${api}/orgs/${encodeURIComponent(owner)}/installation`,
    jwt,
  );
  if (installation.status === 404)
    installation = await githubRequest(
      "GET",
      `${api}/users/${encodeURIComponent(owner)}/installation`,
      jwt,
    );
  if (
    installation.status !== 200 ||
    !installation.json ||
    !Number.isInteger(installation.json.id)
  )
    throw new Error(
      `looking up the App installation for ${owner} answered HTTP ${installation.status}`,
    );
  const minted = await githubRequest(
    "POST",
    `${api}/app/installations/${installation.json.id}/access_tokens`,
    jwt,
    permissions ? { permissions } : undefined,
  );
  const token = minted.json && minted.json.token;
  const expiresAt = minted.json && Date.parse(minted.json.expires_at);
  if (
    minted.status !== 201 ||
    typeof token !== "string" ||
    !token ||
    Number.isNaN(expiresAt)
  )
    throw new Error(
      `minting an installation token answered HTTP ${minted.status}`,
    );
  return { token, expiresAt };
}

/** When to mint next, given a token's expiry and the current time. */
function nextRefreshDelay(expiresAt, now) {
  const untilMargin = expiresAt - REFRESH_MARGIN_MS - now;
  return Math.max(MIN_SLEEP_MS, Math.min(MAX_SLEEP_MS, untilMargin));
}

/** Back off 15s, 30s, ... up to five minutes between failed mints. */
function retryDelay(failures) {
  return Math.min(5 * 60 * 1000, 15 * 1000 * 2 ** Math.max(0, failures - 1));
}

/**
 * Whether `pid` is this job's credential broker. The pid must be a positive
 * decimal, the process must exist and be signalable by us (the broker always
 * runs as the user that started it, so EPERM means some other user's process
 * took the pid over), and, where /proc exposes it, its argv must end with
 * `<...>/job-credentials.cjs daemon` -- so a pid reused by an unrelated process
 * after the broker died is not mistaken for it. Without /proc (macOS) liveness
 * is the whole test. setup-nix's "Configure Nix authentication" step applies
 * the same test in bash; keep the two in step.
 */
function isBrokerProcess(pidText) {
  if (!/^[1-9][0-9]*$/.test(pidText)) return false;
  const pid = Number(pidText);
  if (!Number.isSafeInteger(pid)) return false;
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  let argv;
  try {
    argv = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
  } catch {
    // No procfs on this platform: liveness alone decides. With procfs, an
    // unreadable entry is a pid that exited after the signal: no broker.
    return !fs.existsSync("/proc/self");
  }
  if (argv.at(-1) === "") argv.pop();
  return (
    argv.length >= 2 &&
    argv.at(-1) === "daemon" &&
    path.basename(argv.at(-2)) === "job-credentials.cjs"
  );
}

/**
 * The GitHub token a running broker has installed in `dir`, or "" when no
 * broker owns the job's GitHub credential.
 *
 * OWNERSHIP RULE. Once a broker is running in a job's credential directory it
 * is the only writer of the GitHub entries in that directory. Every other
 * writer -- setup-nix, the Nix-auth selection, refresh-build-auth -- installs
 * this token instead of the one it was handed. The token it was handed is at
 * best as old as the broker's, and usually older: the broker schedules its
 * next mint from the expiry of the token IT installed, so an older token
 * written over it expires with nothing due to replace it. That is the
 * 2026-11-12 incident (codetracer-trace-format PR #70, job 131107655430): a
 * setup-nix run 4 minutes after the broker started wrote the workflow's
 * 42-minute-old `gh-token` back over the broker's fresh one, it expired at
 * minute 60, and the next Nix fetch answered 401 18 minutes before the broker
 * would have rotated.
 *
 * "Running" means: `broker.pid` names a live broker process (isBrokerProcess)
 * and `broker.stop` is absent. A broker that crashed or was stopped owns nothing, and the caller's
 * token is installed as before. setup-nix's "Configure Nix authentication"
 * step applies the same test in bash, because it runs before a Node runtime
 * is bound; keep the two in step.
 */
function brokerGithubToken(dir) {
  if (fs.existsSync(path.join(dir, STOP))) return "";
  let pidText;
  try {
    pidText = fs.readFileSync(path.join(dir, BROKER_PID), "utf8").trim();
  } catch {
    return "";
  }
  if (!isBrokerProcess(pidText)) return "";
  const token = readAccessTokens(dir)["github.com"] || "";
  return /\s/.test(token) ? "" : token;
}

function brokerShouldStop(dir) {
  return (
    !fs.existsSync(path.join(dir, NIX_TOKENS)) ||
    fs.existsSync(path.join(dir, STOP))
  );
}

/**
 * The refresh loop. Exits when the directory is gone (the runner emptied
 * RUNNER_TEMP), when `broker.stop` appears, or after `maxLifetimeMs`.
 * Injected clock/sleep/mint keep the loop testable without real hours.
 */
async function runBroker({
  dir,
  owners,
  mint,
  log = () => {},
  now = () => Date.now(),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  firstDelayMs = 0,
  maxLifetimeMs = DEFAULT_MAX_LIFETIME_MS,
}) {
  const deadline = now() + maxLifetimeMs;
  let wait = firstDelayMs;
  let failures = 0;
  let rotations = 0;
  for (;;) {
    const wakeAt = now() + wait;
    while (now() < wakeAt) {
      if (brokerShouldStop(dir) || now() >= deadline)
        return { rotations, reason: "stopped" };
      await sleep(Math.min(POLL_MS, wakeAt - now()));
    }
    if (brokerShouldStop(dir) || now() >= deadline)
      return { rotations, reason: "stopped" };
    try {
      const { token, expiresAt } = await mint();
      rotate(dir, token, owners);
      rotations += 1;
      failures = 0;
      wait = nextRefreshDelay(expiresAt, now());
      log(
        `rotated the job's Nix GitHub credential; next refresh in ${Math.round(wait / 1000)}s`,
      );
    } catch (error) {
      failures += 1;
      wait = retryDelay(failures);
      // The message names an HTTP status or a file problem, never a secret.
      log(
        `refresh attempt ${failures} failed: ${error.message}; retrying in ${Math.round(wait / 1000)}s`,
      );
    }
  }
}

function ownersFrom(env) {
  const owners = (
    env.TOKEN_OWNERS === undefined ? "metacraft-labs" : env.TOKEN_OWNERS
  )
    .split(/\s+/)
    .filter(Boolean);
  return owners;
}

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () =>
      resolve(Buffer.concat(chunks).toString("utf8")),
    );
    process.stdin.on("error", reject);
  });
}

/** Entry point of the detached child: App credentials arrive on stdin. */
async function daemonMain() {
  const dir = credentialsDir();
  if (!dir) throw new Error("MCL_JOB_CREDENTIALS_DIR is required");
  const secrets = JSON.parse(await readStdin());
  const owners = ownersFrom(process.env);
  const log = (message) =>
    console.log(new Date().toISOString() + " " + message);
  const result = await runBroker({
    dir,
    owners,
    firstDelayMs: Number(process.env.MCL_BROKER_FIRST_DELAY_MS || 0),
    mint: () =>
      mintInstallationToken({
        apiUrl: process.env.GITHUB_API_URL,
        appId: secrets.appId,
        privateKey: secrets.privateKey,
        owner: secrets.owner,
        permissions: { contents: "read" },
      }),
    log,
  });
  log(
    `broker exiting (${result.reason}) after ${result.rotations} rotation(s)`,
  );
}

function mask(value) {
  const escaped = value
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A");
  fs.writeSync(1, "::add-mask::" + escaped + "\n");
}

/**
 * Called from a workflow step: mint once in the foreground (so a bad App ID
 * or key fails the step, and the first broker token is masked in the log),
 * install it, then leave a detached child refreshing it until the job ends.
 */
async function startBroker(env = process.env) {
  let dir = credentialsDir(env);
  if (!dir) {
    // Started before setup-nix: create the directory setup-nix and the
    // Nix-auth selection will then reuse, and hand it to later steps.
    if (!env.RUNNER_TEMP || !env.GITHUB_ENV)
      throw new Error(
        "RUNNER_TEMP and GITHUB_ENV are required to create the job credential directory",
      );
    dir = createCredentialsDir(env.RUNNER_TEMP);
    fs.appendFileSync(
      env.GITHUB_ENV,
      "MCL_JOB_CREDENTIALS_DIR=" + dir + "\n",
      "utf8",
    );
  }
  const appId = (env.APP_ID || "").trim();
  const privateKey = env.APP_PRIVATE_KEY || "";
  if (!/^[0-9]+$/.test(appId))
    throw new Error("app-id must be the numeric GitHub App ID");
  if (!privateKey.includes("PRIVATE KEY"))
    throw new Error("app-private-key is not a PEM private key");
  const owners = ownersFrom(env);
  const owner = (env.APP_OWNER || owners[0] || "").trim();
  if (!owner) throw new Error("no owner to mint the installation token for");
  const minted = await mintInstallationToken({
    apiUrl: env.GITHUB_API_URL,
    appId,
    privateKey,
    owner,
    permissions: { contents: "read" },
  });
  mask(minted.token);
  rotate(dir, minted.token, owners);

  const logFd = fs.openSync(path.join(dir, BROKER_LOG), "a", 0o600);
  const child = spawn(process.execPath, [__filename, "daemon"], {
    detached: true,
    stdio: ["pipe", logFd, logFd],
    env: {
      ...env,
      APP_ID: "",
      APP_PRIVATE_KEY: "",
      MCL_JOB_CREDENTIALS_DIR: dir,
      MCL_BROKER_FIRST_DELAY_MS: String(
        nextRefreshDelay(minted.expiresAt, Date.now()),
      ),
    },
    windowsHide: true,
  });
  child.stdin.end(JSON.stringify({ appId, privateKey, owner }));
  fs.closeSync(logFd);
  writeAtomic(path.join(dir, BROKER_PID), String(child.pid) + "\n");
  child.unref();
  console.log(
    `Job credential broker started (pid ${child.pid}); it re-mints the Nix GitHub credential before it expires. Log: ${path.join(dir, BROKER_LOG)}`,
  );
}

module.exports = {
  NIX_TOKENS,
  NETRC,
  STOP,
  DIR_PREFIX,
  credentialsDir,
  createCredentialsDir,
  includeLine,
  isIncludeLine,
  formatAccessTokens,
  netrcLine,
  readAccessTokens,
  writeAccessTokens,
  withGithubToken,
  rotateNetrc,
  rotate,
  appJwt,
  mintInstallationToken,
  nextRefreshDelay,
  retryDelay,
  brokerGithubToken,
  runBroker,
  startBroker,
};

if (require.main === module) {
  const command = process.argv[2];
  const run =
    command === "daemon"
      ? daemonMain
      : command === "start"
        ? () => startBroker()
        : null;
  if (!run) {
    console.error("usage: job-credentials.cjs start|daemon");
    process.exit(2);
  }
  run().catch((error) => {
    console.error("job-credentials: " + error.message);
    process.exit(1);
  });
}
