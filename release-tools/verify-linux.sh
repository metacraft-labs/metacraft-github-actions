#!/usr/bin/env bash
# Run the shipped archives and install the actual packages without a Nix store.
set -euo pipefail
: "${RELEASE_NODE:?}" "${RELEASE_TARGET:?}" "${RELEASE_VERSION:?}"
docker info >/dev/null
product="$($RELEASE_NODE -p 'require("./.github/release.json").product')"
name="$product-$RELEASE_VERSION-$RELEASE_TARGET"
# Persistent NixOS runners can have a private /tmp namespace that the Docker
# daemon does not share. Bind a workspace directory visible to both processes.
work="$(mktemp -d "$PWD/build/release-portability.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/archives" "$work/checks" "$work/packages"
tar -xzf "dist/$name.tar.gz" -C "$work/archives"
node_arch=x64
node_hash=fb870226119d47378fa9c92c4535389c72dae14fcc7b47e6fdcc82c43de5a547
if [ "$RELEASE_TARGET" = linux-aarch64 ]; then
  node_arch=arm64
  node_hash=1725602e9fb150eb8b8220a899085190e1c04d1a5f3862b01c3dc1dfce0157f9
fi
# The runner's Node can be patched to a Nix loader. Use a pinned upstream
# test driver that can actually execute in the clean distribution images.
curl --fail --location --retry 3 "https://nodejs.org/dist/v22.16.0/node-v22.16.0-linux-$node_arch.tar.gz" -o "$work/node.tar.gz"
printf '%s  %s\n' "$node_hash" "$work/node.tar.gz" | sha256sum -c -
tar -xzf "$work/node.tar.gz" -C "$work" --strip-components=2 "node-v22.16.0-linux-$node_arch/bin/node"
cp scripts/release/smoke.cjs "$work/checks/smoke.cjs"
cp "$RELEASE_TOOLS/verify-configuration.cjs" "$work/checks/verify-configuration.cjs"
"$RELEASE_NODE" - "$work/checks/configuration.json" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const {configurationFiles} = require(path.join(process.env.RELEASE_TOOLS, 'payload.cjs'));
const spec = JSON.parse(fs.readFileSync('.github/release.json'));
const metadata = spec.distributionMetadata ? JSON.parse(fs.readFileSync(spec.distributionMetadata)) : {};
fs.writeFileSync(process.argv[2], JSON.stringify(configurationFiles(metadata).map(entry => ({
  destination: entry.destination, bytes: fs.readFileSync(entry.source).toString('base64'),
}))));
NODE
cp dist/*.deb dist/*.rpm "$work/packages/"
if [ "$product" = io-mon ]; then cp build/release-probe "$work/checks/probe"; fi
images=(debian:11 ubuntu:24.04 almalinux:9)
for image in "${images[@]}"; do
  docker pull "$image"
  docker image inspect --format '{{index .RepoDigests 0}}' "$image" >> test-logs/portability-images.txt
  docker run --rm --network bridge -v "$work:/payload:ro" \
    -e PRODUCT="$product" -e ARCHIVE_NAME="$name" -e TARGET="$RELEASE_TARGET" \
    "$image" sh -eu -c '
      test -s /payload/node
      test -d /payload/archives
      if command -v apt-get >/dev/null; then
        apt-get update -qq
        apt-get install -y --no-install-recommends libstdc++6
        dpkg -i /payload/packages/*.deb
      else
        dnf install -y libstdc++ /payload/packages/*.rpm
      fi
      /payload/node /payload/checks/verify-configuration.cjs /payload/checks/configuration.json check
      /payload/node /payload/checks/verify-configuration.cjs /payload/checks/configuration.json mark
      if command -v apt-get >/dev/null; then
        dpkg -i /payload/packages/*.deb
      else
        dnf reinstall -y /payload/packages/*.rpm
      fi
      /payload/node /payload/checks/verify-configuration.cjs /payload/checks/configuration.json preserved
      mkdir -p /tmp/smoke
      cd /tmp/smoke
      /payload/node /payload/checks/smoke.cjs "/payload/archives/$ARCHIVE_NAME" "$TARGET" /payload/checks/probe
      rm -f release-probe-*
      /payload/node /payload/checks/smoke.cjs "/usr/lib/$PRODUCT" "$TARGET" /payload/checks/probe
    '
done
"$RELEASE_NODE" - "$name" <<'NODE'
const fs = require('node:fs');
const file = `dist/${process.argv[2]}.json`;
const evidence = JSON.parse(fs.readFileSync(file));
evidence.smoke = 'passed';
evidence.portabilityImages = fs.readFileSync('test-logs/portability-images.txt', 'utf8').trim().split('\n');
fs.writeFileSync(file, JSON.stringify(evidence, null, 2) + '\n');
NODE
