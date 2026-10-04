// No mocks: build real deb, RPM and Arch packages, inspect their metadata,
// extract the payloads and compare the canonical configuration bytes.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const cp = require("node:child_process");
const { nativePackages } = require("./payload.cjs");
const run = (exe, args, opts = {}) =>
  cp.execFileSync(exe, args, { encoding: "utf8", ...opts });

test("all native packages carry the exact config and preservation metadata", (t) => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "release-config-"));
  t.after(() => fs.rmSync(work, { recursive: true, force: true }));
  const tree = path.join(work, "payload");
  fs.mkdirSync(path.join(tree, "bin"), { recursive: true });
  for (const name of ["runquota", "runquotad"]) {
    fs.writeFileSync(
      path.join(tree, "bin", name),
      '#!/bin/sh\nprintf "package control\\n"\n',
      { mode: 0o755 },
    );
  }
  fs.writeFileSync(path.join(tree, "LICENSE"), "package control license\n");
  const canonical = Buffer.from(
    "# Operator-owned budget\n# memory_bytes = 123\n",
  );
  const source = path.join(work, "runquotad.toml");
  fs.writeFileSync(source, canonical, { mode: 0o600 });
  const archMetadata = path.join(work, "PKGINFO");
  const archName = process.arch === "arm64" ? "aarch64" : "x86_64";
  const target = `linux-${archName}`;
  const assets = ["runquota.deb", "runquota.rpm", "runquota.pkg.tar.gz"];
  const plan = {
    product: "runquota",
    version: "1.2.3",
    matrix: [{ id: target, assets }],
  };
  for (const withConfig of [true, false]) {
    const output = path.join(work, withConfig ? "configured" : "plain");
    fs.mkdirSync(output);
    fs.writeFileSync(
      archMetadata,
      `pkgname = runquota\npkgver = 1.2.3-1\narch = ${archName}\nsize = @INSTALLED_SIZE@\n` +
        (withConfig ? "backup = etc/runquota/runquotad.toml\n" : ""),
    );
    nativePackages(
      tree,
      target,
      {
        packageName: "runquota",
        commands: ["runquota", "runquotad"],
        summary: "Package control",
        license: "MIT",
        archMetadata,
        configurationFiles: withConfig
          ? [{ source, destination: "/etc/runquota/runquotad.toml" }]
          : [],
      },
      plan,
      output,
    );
    const deb = path.join(output, assets[0]);
    const rpm = path.join(output, assets[1]);
    const arch = path.join(output, assets[2]);
    const control = path.join(output, "control");
    run("dpkg-deb", ["-e", deb, control]);
    assert.equal(fs.existsSync(path.join(control, "conffiles")), withConfig);
    const rpmFiles = run("rpm", [
      "-qp",
      "--qf",
      "[%{FILENAMES}\t%{FILEFLAGS:fflags}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\n]",
      rpm,
    ]);
    const info = run("bsdtar", ["-xOf", arch, ".PKGINFO"]);
    assert.equal(
      info.includes("backup = etc/runquota/runquotad.toml\n"),
      withConfig,
    );
    if (withConfig) {
      assert.equal(
        fs.readFileSync(path.join(control, "conffiles"), "utf8"),
        "/etc/runquota/runquotad.toml\n",
      );
      const row = rpmFiles
        .split("\n")
        .find((line) => line.startsWith("/etc/runquota/runquotad.toml\t"))
        .split("\t");
      assert(row[1].includes("c") && row[1].includes("n"), row.join(" "));
      assert.deepEqual(row.slice(2), ["root", "root"]);
    } else assert(!rpmFiles.includes("/etc/"));
    for (const [kind, file] of [
      ["deb", deb],
      ["rpm", rpm],
      ["arch", arch],
    ]) {
      const unpacked = path.join(output, kind);
      fs.mkdirSync(unpacked);
      if (kind === "deb") run("dpkg-deb", ["-x", file, unpacked]);
      else if (kind === "rpm") {
        const cpio = cp.execFileSync("rpm2cpio", [file]);
        run("bsdtar", ["--no-same-owner", "-xf", "-", "-C", unpacked], {
          input: cpio,
        });
      } else run("bsdtar", ["--no-same-owner", "-xf", file, "-C", unpacked]);
      const installed = path.join(unpacked, "etc/runquota/runquotad.toml");
      assert.equal(fs.existsSync(installed), withConfig, kind);
      if (withConfig) {
        assert.deepEqual(fs.readFileSync(installed), canonical, kind);
        assert.equal(fs.statSync(installed).mode & 0o777, 0o644, kind);
        assert.equal(
          fs.statSync(path.dirname(installed)).mode & 0o777,
          0o755,
          kind,
        );
      }
    }
  }
});
