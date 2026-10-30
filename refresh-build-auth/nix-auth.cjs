// Single owner of job-scoped Nix access-token refresh. Callers supply an
// explicitly bound Actions/owner Node runtime; no runtime is installed here.
const fs = require("node:fs");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

function refreshNix() {
  const result = spawnSync(
    "nix",
    ["--extra-experimental-features", "nix-command", "show-config", "--json"],
    {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  if (result.error && result.error.code === "ENOENT") {
    console.log("Nix is absent; no Nix authentication configuration is needed");
    return;
  }
  // Never forward parser output/errors: inherited configuration can contain
  // credentials, including in a malformed setting's diagnostic.
  if (result.error || result.status !== 0)
    throw new Error("Cannot read effective Nix authentication settings");
  let tokens;
  try {
    tokens = JSON.parse(result.stdout)["access-tokens"].value;
    if (
      !tokens ||
      Array.isArray(tokens) ||
      typeof tokens !== "object" ||
      Object.values(tokens).some((value) => typeof value !== "string")
    )
      throw new Error();
  } catch {
    throw new Error("Cannot decode effective Nix authentication settings");
  }
  const fresh = process.env.GH_TOKEN || "";
  const github = Object.keys(tokens).filter(
    (host) => host === "github.com" || host.startsWith("github.com/"),
  );
  if (!fresh && github.some((host) => tokens[host] !== "")) {
    throw new Error(
      "Empty gh-token refuses inherited GitHub authentication; provide this job's credential explicitly",
    );
  }
  if (!fresh && github.length === 0) {
    console.log("No GitHub access-token entry is configured or requested");
    return;
  }
  const originalValues = Object.values(tokens);
  if (fresh) {
    tokens["github.com"] = fresh;
    const owners =
      process.env.TOKEN_OWNERS === undefined
        ? "metacraft-labs"
        : process.env.TOKEN_OWNERS;
    for (const owner of owners.split(/\s+/).filter(Boolean)) {
      const prefix = "github.com/" + owner;
      if (Object.hasOwn(tokens, prefix)) tokens[prefix] = fresh;
    }
  } else {
    // Empty entries are not usable credentials; remove them for this job's
    // explicit no-token selection without changing other hosts or HOME files.
    for (const host of github) delete tokens[host];
  }
  if (!process.env.GITHUB_ENV)
    throw new Error("GitHub job environment file is required");
  // Synchronous writes provide the same before-export guarantee as Python's
  // flush=True. Workflow-command escaping is data escaping, not shell quoting.
  for (const value of new Set([...originalValues, fresh])) {
    if (value) {
      const line = Buffer.from(
        "::add-mask::" +
          value
            .replaceAll("%", "%25")
            .replaceAll("\r", "%0D")
            .replaceAll("\n", "%0A") +
          "\n",
      );
      let written = 0;
      while (written < line.length)
        written += fs.writeSync(1, line, written, line.length - written);
    }
  }
  let config = (process.env.NIX_CONFIG || "").replace(/\n+$/, "");
  config +=
    "\naccess-tokens = " +
    Object.keys(tokens)
      .sort()
      .map((host) => host + "=" + tokens[host])
      .join(" ") +
    "\n";
  const delimiter = "nix_auth_" + crypto.randomUUID().replaceAll("-", "");
  fs.appendFileSync(
    process.env.GITHUB_ENV,
    "NIX_CONFIG<<" + delimiter + "\n" + config + delimiter + "\n",
    "utf8",
  );
  console.log(
    fresh
      ? "Refreshed job-scoped Nix GitHub authentication"
      : "Configured no GitHub access-token entry",
  );
}

module.exports = { refreshNix };
if (require.main === module) refreshNix();
