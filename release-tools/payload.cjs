// Package and verify the product's explicit install tree. No build-tree globbing.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const os = require('node:os');
const {plan, digest} = require('./release.cjs');
function run(exe, args, opts = {}) {
  return cp.execFileSync(exe, args, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts}).trim();
}
const fail = message => { throw new Error(message); };
function files(dir) {
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap(e => {
    const p = path.join(dir, e.name);
    return e.isDirectory() ? files(p) : e.isFile() ? [p] : [];
  });
}
function architecture(file, target) {
  const b = fs.readFileSync(file);
  const arm = target.endsWith('aarch64');
  if (b.subarray(0, 4).equals(Buffer.from([0x7f, 69, 76, 70]))) {
    if (b[4] !== 2 || b.readUInt16LE(18) !== (arm ? 183 : 62)) fail(`ELF architecture mismatch: ${file}`);
    return 'elf';
  }
  if (b.subarray(0, 2).toString() === 'MZ') {
    const off = b.readUInt32LE(60);
    if (b.toString('ascii', off, off + 4) !== 'PE\0\0' || b.readUInt16LE(off + 4) !== (arm ? 0xaa64 : 0x8664)) {
      fail(`PE architecture mismatch: ${file}`);
    }
    return 'pe';
  }
  if (target.startsWith('darwin') && /Mach-O/.test(run('file', ['-Lb', file]))) {
    const arch = arm ? 'arm64' : 'x86_64';
    run('lipo', [file, '-verify_arch', arch]);
    return 'macho';
  }
  return '';
}
function relocateLinux(tree, target) {
  const libdir = path.join(tree, 'lib');
  const system = /^(libc\.so|libm\.so|libdl\.so|librt\.so|libpthread\.so|ld-linux|linux-vdso)/;
  let todo = files(tree).filter(f => architecture(f, target) === 'elf');
  const seen = new Set();
  while (todo.length) {
    const file = todo.shift();
    if (seen.has(file)) continue;
    seen.add(file);
    const versions = [...run('readelf', ['--version-info', file]).matchAll(/GLIBC_(\d+)\.(\d+)/g)];
    if (versions.some(m => +m[1] > 2 || (+m[1] === 2 && +m[2] > 28))) fail(`glibc > 2.28 required by ${file}`);
    const deps = run('ldd', [file]);
    if (/not found/.test(deps)) fail(`unresolved runtime dependency in ${file}: ${deps}`);
    for (const m of deps.matchAll(/^\s*(\S+) => (\/\S+) /gm)) {
      if (system.test(m[1])) continue;
      const dest = path.join(libdir, m[1]);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(m[2], dest);
        todo.push(dest);
      } else if (digest(m[2]) !== digest(dest) && !seen.has(dest)) fail(`runtime library collision: ${m[1]}`);
    }
    // Zig already supplies a system interpreter. Enforce it for every binary.
    const header = run('readelf', ['-l', file]);
    if (/Requesting program interpreter:/.test(header)) {
      run('patchelf', ['--set-interpreter', target.endsWith('aarch64') ? '/lib/ld-linux-aarch64.so.1' : '/lib64/ld-linux-x86-64.so.2', file]);
    }
    run('patchelf', ['--set-rpath', '$ORIGIN/../lib:$ORIGIN', file]);
  }
}
function verifyDarwin(tree, target) {
  for (const file of files(tree)) {
    if (architecture(file, target) !== 'macho') continue;
    if (file.endsWith('.dylib')) {
      run('install_name_tool', ['-id', '@rpath/' + path.basename(file), file]);
    }
    const dependencies = run('otool', ['-L', file]).split('\n').slice(1);
    for (const line of dependencies) {
      const dep = line.trim().split(' ')[0];
      if (dep.startsWith('/') && !dep.startsWith('/usr/lib/') && !dep.startsWith('/System/')) {
        fail(`non-system absolute Mach-O dependency in ${file}: ${dep}`);
      }
    }
    // Ad-hoc signing makes modified local payloads executable. This is never
    // recorded as Developer ID signing or notarization in the release evidence.
    run('codesign', ['--force', '--sign', '-', file]);
    run('codesign', ['--verify', '--strict', file]);
  }
}
function nativePackages(tree, target, spec, p, dist) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'tool-packages-'));
  try {
    const root = path.join(temp, 'root');
    const prefix = `/usr/lib/${p.product}`;
    fs.mkdirSync(path.join(root, prefix), {recursive: true});
    fs.cpSync(tree, path.join(root, prefix), {recursive: true, dereference: false, verbatimSymlinks: true});
    fs.mkdirSync(path.join(root, 'usr/bin'), {recursive: true});
    for (const cmd of spec.commands) {
      const wrapper = path.join(root, 'usr/bin', cmd);
      fs.writeFileSync(wrapper, `#!/bin/sh\nexec ${prefix}/bin/${cmd} "$@"\n`, {mode: 0o755});
    }
    // The product owns service semantics. Copy its service metadata verbatim.
    if (spec.systemdUnit) {
      const dest = path.join(root, 'usr/lib/systemd/system');
      fs.mkdirSync(dest, {recursive: true});
      fs.copyFileSync(spec.systemdUnit, path.join(dest, `${spec.serviceName}.service`));
    }
    const debArch = target.endsWith('aarch64') ? 'arm64' : 'amd64';
    const rpmArch = target.endsWith('aarch64') ? 'aarch64' : 'x86_64';
    const deb = p.matrix.find(t => t.id === target).assets.find(a => a.endsWith('.deb'));
    const rpm = p.matrix.find(t => t.id === target).assets.find(a => a.endsWith('.rpm'));
    if (deb) {
      fs.mkdirSync(path.join(root, 'DEBIAN'));
      fs.writeFileSync(path.join(root, 'DEBIAN/control'),
        `Package: ${spec.packageName}\nVersion: ${p.version}-1\nArchitecture: ${debArch}\nMaintainer: Metacraft Labs <info@metacraft-labs.com>\nDepends: libc6 (>= 2.28)\n` +
        (spec.recommends?.length ? `Recommends: ${spec.recommends.join(', ')}\n` : '') +
        `Description: ${spec.summary}\n`);
      run('dpkg-deb', ['--root-owner-group', '--build', root, path.join(dist, deb)]);
      if (run('dpkg-deb', ['-f', path.join(dist, deb), 'Architecture']) !== debArch) fail('deb architecture mismatch');
      fs.rmSync(path.join(root, 'DEBIAN'), {recursive: true});
    }
    if (rpm) {
      const rpmdir = path.join(temp, 'rpm');
      fs.mkdirSync(rpmdir);
      const specfile = path.join(temp, 'package.spec');
      fs.writeFileSync(specfile,
        `Name: ${spec.packageName}\nVersion: ${p.version}\nRelease: 1\nSummary: ${spec.summary}\nLicense: ${spec.license}\nBuildArch: ${rpmArch}\nRequires: glibc >= 2.28\nAutoReqProv: no\n` +
        `%description\n${spec.summary}\n%install\nmkdir -p %{buildroot}\ncp -a '${root}/.' %{buildroot}/\n%files\n/usr/bin/*\n${prefix}\n` +
        (spec.systemdUnit ? `/usr/lib/systemd/system/${spec.serviceName}.service\n` : ''));
      run('rpmbuild', ['-bb', '--target', rpmArch, '--define', `_topdir ${rpmdir}`,
        '--define', '__os_install_post %{nil}', '--define', '_build_id_links none', specfile]);
      const built = files(rpmdir).filter(f => f.endsWith('.rpm'));
      if (built.length !== 1) fail('expected exactly one rpm');
      fs.copyFileSync(built[0], path.join(dist, rpm));
      if (run('rpm', ['-qp', '--qf', '%{ARCH}', path.join(dist, rpm)]) !== rpmArch) fail('rpm architecture mismatch');
    }
  } finally { fs.rmSync(temp, {recursive: true, force: true}); }
}
function packagePayload(tree, target) {
  const spec = JSON.parse(fs.readFileSync('.github/release.json'));
  const p = plan();
  const t = p.matrix.find(t => t.id === target);
  if (!t) fail(`unknown target ${target}`);
  const windows = target.startsWith('windows');
  for (const cmd of spec.commands) {
    const exe = path.join(tree, 'bin', cmd + (windows ? '.exe' : ''));
    if (!fs.existsSync(exe)) fail(`missing command ${exe}`);
    const kind = architecture(exe, target);
    const expectedKind = windows ? 'pe' : target.startsWith('linux') ? 'elf' : 'macho';
    if (kind !== expectedKind) fail(`command is not a target binary: ${exe}`);
  }
  if (target.startsWith('linux')) relocateLinux(tree, target);
  if (target.startsWith('darwin')) verifyDarwin(tree, target);
  const dist = path.resolve('dist');
  fs.mkdirSync(dist, {recursive: true});
  const name = `${p.product}-${p.version}-${target}`;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'release-extraction-'));
  try {
    fs.cpSync(tree, path.join(work, name), {recursive: true, dereference: false, verbatimSymlinks: true});
    const archive = t.assets.find(a => /\.(tar\.gz|zip)$/.test(a));
    if (!archive) fail(`no archive for ${target}`);
    if (windows) {
      // PowerShell receives paths through environment variables, never script interpolation.
      run('pwsh', ['-NoProfile', '-Command', 'Compress-Archive -LiteralPath $env:PAYLOAD -DestinationPath $env:ARCHIVE -Force'],
        {env: {...process.env, PAYLOAD: path.join(work, name), ARCHIVE: path.join(dist, archive)}});
    } else run('tar', ['-czf', path.join(dist, archive), '-C', work, name]);
    fs.rmSync(path.join(work, name), {recursive: true});
    if (windows) run('pwsh', ['-NoProfile', '-Command', 'Expand-Archive -LiteralPath $env:ARCHIVE -DestinationPath $env:UNPACK'],
      {env: {...process.env, ARCHIVE: path.join(dist, archive), UNPACK: work}});
    else run('tar', ['-xzf', path.join(dist, archive), '-C', work]);
    // Smoke the extracted bytes, with a new working directory and a minimal environment.
    const smoke = path.resolve('scripts/release/smoke.cjs');
    const env = {PATH: windows ? `${process.env.SystemRoot}\\System32;${process.env.SystemRoot}` : '/usr/bin:/bin:/usr/sbin:/sbin', HOME: work, TMPDIR: work, TEMP: work,
      SystemRoot: process.env.SystemRoot, WINDIR: process.env.WINDIR};
    run(process.execPath, [smoke, path.join(work, name), target, process.env.RELEASE_SMOKE_PROBE || ''], {cwd: work, env});
    if (target.startsWith('linux')) nativePackages(path.join(work, name), target, spec, p, dist);
  } finally { fs.rmSync(work, {recursive: true, force: true}); }
  const evidence = {product: p.product, version: p.version, target,
    sourceCommit: run('git', ['rev-parse', 'HEAD']),
    binarySigningVerified: false, smoke: 'passed',
    artifacts: Object.fromEntries(fs.readdirSync(dist).filter(n => !n.endsWith('.json')).map(n => [n, digest(path.join(dist, n))]))};
  fs.writeFileSync(path.join(dist, name + '.json'), JSON.stringify(evidence, null, 2) + '\n');
  console.log(`Verified ${name} at ${evidence.sourceCommit}`);
}
module.exports = {architecture, packagePayload};
if (require.main === module) packagePayload(path.resolve(process.argv[2]), process.argv[3]);
