#!/usr/bin/env bash
# Run the shipped archives and install the actual packages without a Nix store.
set -euo pipefail
: "${RELEASE_NODE:?}" "${RELEASE_TARGET:?}" "${RELEASE_VERSION:?}"
docker info >/dev/null
product="$($RELEASE_NODE -p 'require("./.github/release.json").product')"
name="$product-$RELEASE_VERSION-$RELEASE_TARGET"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/archives" "$work/checks" "$work/packages"
tar -xzf "dist/$name.tar.gz" -C "$work/archives"
cp "$RELEASE_NODE" "$work/node"
cp scripts/release/smoke.cjs "$work/checks/smoke.cjs"
cp dist/*.deb dist/*.rpm "$work/packages/"
if [ "$product" = io-mon ]; then cp build/release-probe "$work/checks/probe"; fi
images=(debian:11 ubuntu:24.04 almalinux:9)
for image in "${images[@]}"; do
  docker pull "$image"
  docker image inspect --format '{{index .RepoDigests 0}}' "$image" >> test-logs/portability-images.txt
  docker run --rm --network bridge -v "$work:/payload:ro" \
    -e PRODUCT="$product" -e ARCHIVE_NAME="$name" -e TARGET="$RELEASE_TARGET" \
    "$image" sh -eu -c '
      if command -v apt-get >/dev/null; then
        apt-get update -qq
        apt-get install -y --no-install-recommends libstdc++6 ca-certificates
        dpkg -i /payload/packages/*.deb
      else
        dnf install -y libstdc++ /payload/packages/*.rpm
      fi
      mkdir -p /tmp/smoke
      cd /tmp/smoke
      /payload/node /payload/checks/smoke.cjs "/payload/archives/$ARCHIVE_NAME" "$TARGET" /payload/checks/probe
      rm -f release-probe-*
      /payload/node /payload/checks/smoke.cjs "/usr/lib/$PRODUCT" "$TARGET" /payload/checks/probe
    '
done
