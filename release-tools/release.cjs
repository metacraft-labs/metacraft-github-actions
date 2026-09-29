// Shared release planning and verification. Product metadata lives in the caller.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');

const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const run = (...args) => cp.execFileSync(args[0], args.slice(1), {encoding: 'utf8'}).trim();
const assert = (condition, message) => { if (!condition) throw new Error(message); };

function plan(root = process.cwd(), hosted = false) {
  const spec = JSON.parse(fs.readFileSync(path.join(root, '.github/release.json')));
  assert(/^[a-z][a-z0-9-]*$/.test(spec.product), 'invalid product name');
  const source = fs.readFileSync(path.join(root, spec.versionFile), 'utf8');
  const version = spec.versionFile.endsWith('.txt') ? source.trim() :
    source.match(/^\s*version\s*=\s*"([^"]+)"/m)?.[1];
  assert(/^\d+\.\d+\.\d+$/.test(version), 'expected a stable three-part version');
  const unsignedRelease = spec.unsignedReleaseVersion !== undefined;
  if (unsignedRelease) {
    assert(spec.unsignedReleaseVersion === version,
      'unsigned release exception does not cover this version');
  }
  for (const check of spec.versionChecks || []) {
    const value = fs.readFileSync(path.join(root, check.file), 'utf8').match(new RegExp(check.pattern, 'm'))?.[1];
    assert(value === version, `version disagreement in ${check.file}`);
  }
  assert(Array.isArray(spec.targets) && spec.targets.length > 0, 'empty target matrix');
  const expand = s => s.replaceAll('{product}', spec.product).replaceAll('{version}', version);
  const matrix = spec.targets.map(t => {
    assert(/^(linux|darwin|windows)-(x86_64|aarch64)$/.test(t.id), `invalid target ${t.id}`);
    const capabilityRunner = Array.isArray(t.runner) && t.runner.includes('self-hosted');
    const releaseLane = t.id === 'linux-x86_64' && t.runner === 'eph-linux-x64-release';
    // The Linux ARM64 Tart pool is not yet serving jobs. Its documented
    // scale-set route is still live; keep the exception narrow and explicit.
    const legacyArmRunner = t.id === 'linux-aarch64' && t.runner === 'eph-linux-arm64' &&
      typeof t.runnerReason === 'string' && t.runnerReason.trim().length > 0;
    const migration = t.runnerMigration;
    const migrationValid = migration?.version === version && typeof migration.owner === 'string' &&
      migration.owner.trim().length > 0 && typeof migration.followup === 'string' &&
      migration.followup.startsWith('https://github.com/metacraft-labs/metacraft-specs/');
    const hostedArmRunner = ((t.id === 'linux-aarch64' && t.runner === 'ubuntu-24.04-arm') ||
      (t.id === 'windows-aarch64' && t.runner === 'windows-11-arm')) && migrationValid;
    assert(capabilityRunner || releaseLane || legacyArmRunner || hostedArmRunner,
      'self-hosted runner required; legacy ARM routing needs a reason and hosted ARM needs a version-scoped migration');
    if (t.hostedRunner !== undefined) {
      const nativeHosted = (t.id === 'linux-x86_64' && t.hostedRunner === 'ubuntu-24.04') ||
        (t.id === 'darwin-aarch64' && t.hostedRunner === 'macos-26');
      assert(nativeHosted && migrationValid,
        'hosted alternative needs a native standard runner and a version-scoped migration');
    }
    assert(Array.isArray(t.assets) && t.assets.length > 0, `no assets for ${t.id}`);
    const assets = t.assets.map(expand);
    assert(assets.every(a => /^[A-Za-z0-9_.+-]+$/.test(a)), 'unsafe asset name');
    assert(t.id.startsWith('windows-') || !assets.some(a => a.endsWith('.msi')), 'MSI requires a Windows target');
    return {...t, runner: hosted && t.hostedRunner ? t.hostedRunner : t.runner, assets};
  });
  const expected = matrix.flatMap(t => t.assets).sort();
  assert(new Set(matrix.map(t => t.id)).size === matrix.length, 'duplicate target');
  assert(new Set(expected).size === expected.length, 'duplicate asset');
  const hasMsi = expected.some(a => a.endsWith('.msi'));
  const msiRunner = matrix.find(t => t.id === "windows-aarch64")?.runner ||
    ["self-hosted", "windows", "arm64"];
  return {product: spec.product, version, matrix, expected, hasMsi, unsignedRelease, msiRunner};
}

function verifyDirectory(dir, expected, sidecars = true) {
  const actual = fs.readdirSync(dir).filter(n => !n.endsWith('.sha256')).sort();
  assert(JSON.stringify(actual) === JSON.stringify([...expected].sort()),
    `asset set differs: expected ${expected.join(', ')}, found ${actual.join(', ')}`);
  for (const name of expected) {
    const file = path.join(dir, name);
    assert(fs.lstatSync(file).isFile() && fs.statSync(file).size > 0, `empty/non-file asset ${name}`);
    if (sidecars) {
      assert(fs.readFileSync(file + '.sha256', 'utf8') === `${digest(file)}  ${name}\n`,
        `checksum mismatch for ${name}`);
    }
  }
  if (sidecars) {
    assert(fs.readdirSync(dir).length === expected.length * 2, 'unexpected checksum sidecar');
  }
}

function seal(dir, expected) {
  verifyDirectory(dir, expected, false);
  for (const name of expected) {
    fs.writeFileSync(path.join(dir, name + '.sha256'), `${digest(path.join(dir, name))}  ${name}\n`);
  }
}

function assemble(dir, expected) {
  verifyDirectory(dir, expected);
  const sums = expected.slice().sort().map(n => fs.readFileSync(path.join(dir, n + '.sha256'), 'utf8')).join('');
  fs.writeFileSync(path.join(dir, 'SHA256SUMS'), sums);
  for (const name of expected) fs.unlinkSync(path.join(dir, name + '.sha256'));
}

async function githubPlan({github, context, core}) {
  const p = plan(process.cwd(), process.env.RELEASE_HOSTED === 'true');
  const sha = run('git', 'rev-parse', 'HEAD');
  assert(sha === context.sha, 'checkout differs from triggering commit');
  if (context.eventName === 'push' && context.ref.startsWith('refs/tags/')) {
    assert(context.ref === `refs/tags/v${p.version}`, 'tag and source version disagree');
    run('git', 'fetch', 'origin', 'dev');
    run('git', 'merge-base', '--is-ancestor', sha, 'FETCH_HEAD');
    const workflowPath = '.github/workflows/release.yml';
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      ...context.repo, workflow_id: workflowPath, event: 'workflow_dispatch',
      head_sha: sha, status: 'success', per_page: 100,
    });
    assert(runs.some(r => r.head_sha === sha && r.conclusion === 'success'),
      `no successful release dry run for ${sha}`);
  }
  core.setOutput('matrix', JSON.stringify(p.matrix));
  core.setOutput('version', p.version);
  core.setOutput('expected', JSON.stringify(p.expected));
  core.setOutput('has-msi', String(p.hasMsi));
  core.setOutput('msi-runner', JSON.stringify(p.msiRunner));
  core.setOutput('unsigned-release', String(p.unsignedRelease));
  core.exportVariable('RELEASE_NODE', process.execPath);
}

async function publish({github, context, core}) {
  assert(context.eventName === 'push' && context.ref.startsWith('refs/tags/v'), 'only tag pushes publish');
  const p = plan();
  const tag = `v${p.version}`;
  assert(context.ref === `refs/tags/${tag}`, 'tag mismatch');
  const dir = 'dist';
  const expected = [...p.expected, 'SHA256SUMS',
    ...(p.unsignedRelease ? [] : ['SHA256SUMS.sigstore.json'])].sort();
  verifyDirectory(dir, expected, false);
  // Signed releases pass attestation verification first. Both policies must
  // verify all transferred bytes and the manifest before publication.
  const sums = p.expected.map(n => `${digest(path.join(dir, n))}  ${n}\n`).join('');
  assert(fs.readFileSync(path.join(dir, 'SHA256SUMS'), 'utf8') === sums, 'manifest differs from assets');
  const releases = await github.paginate(github.rest.repos.listReleases, {...context.repo, per_page: 100});
  let release = releases.find(r => r.tag_name === tag);
  if (!release) {
    release = (await github.rest.repos.createRelease({
      ...context.repo, tag_name: tag, target_commitish: context.sha,
      name: `${p.product} ${tag}`, draft: true, generate_release_notes: true,
      body: `Targets: ${p.matrix.map(t => t.id).join(', ')}.\n\n` +
        (p.unsignedRelease ? 'This initial release is unsigned under the approved first-release exception. SHA256SUMS records all artifact hashes.\n' : ''),
    })).data;
  }
  const existing = await github.paginate(github.rest.repos.listReleaseAssets, {
    ...context.repo, release_id: release.id, per_page: 100,
  });
  assert(existing.every(a => expected.includes(a.name)), 'release has unexpected assets');
  for (const name of expected) {
    const file = path.join(dir, name);
    const old = existing.find(a => a.name === name);
    if (old) {
      const bytes = await github.request('GET /repos/{owner}/{repo}/releases/assets/{asset_id}', {
        ...context.repo, asset_id: old.id, headers: {accept: 'application/octet-stream'},
      });
      assert(Buffer.from(bytes.data).equals(fs.readFileSync(file)), `refusing to replace published ${name}`);
    } else {
      assert(release.draft, `published release is missing ${name}; refusing mutation`);
      await github.rest.repos.uploadReleaseAsset({
        ...context.repo, release_id: release.id, name,
        data: fs.readFileSync(file), headers: {'content-type': 'application/octet-stream'},
      });
    }
  }
  // Re-download every asset from GitHub before making the draft visible.
  const uploaded = await github.paginate(github.rest.repos.listReleaseAssets, {
    ...context.repo, release_id: release.id, per_page: 100,
  });
  assert(uploaded.length === expected.length, 'uploaded asset count differs');
  for (const asset of uploaded) {
    assert(expected.includes(asset.name), `unexpected uploaded asset ${asset.name}`);
    const response = await github.request('GET /repos/{owner}/{repo}/releases/assets/{asset_id}', {
      ...context.repo, asset_id: asset.id, headers: {accept: 'application/octet-stream'},
    });
    assert(Buffer.from(response.data).equals(fs.readFileSync(path.join(dir, asset.name))),
      `uploaded bytes differ for ${asset.name}`);
  }
  if (release.draft) await github.rest.repos.updateRelease({...context.repo, release_id: release.id, draft: false});
  core.setOutput('tag', tag);
  core.notice(`Published ${release.html_url} at ${context.sha}`);
}

module.exports = {plan, digest, seal, assemble, verifyDirectory, githubPlan, publish};
if (require.main === module) {
  const [verb, dir, target] = process.argv.slice(2);
  const p = plan();
  if (verb === 'seal') {
    const t = p.matrix.find(t => t.id === target);
    assert(t, `unknown target ${target}`);
    seal(dir, t.assets);
  } else if (verb === 'assemble') assemble(dir, p.expected);
  else if (verb === 'plan') console.log(JSON.stringify(p, null, 2));
  else throw new Error(`unknown command ${verb}`);
}
