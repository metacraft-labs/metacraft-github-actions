#!/usr/bin/env bash
# Source from the product's release recipe, inside its pinned dev environment.
set -euo pipefail
: "${RELEASE_TOOLS:?set RELEASE_TOOLS to metacraft-github-actions/release-tools}"
release_target="${1:?release target required}"
release_arch="${release_target##*-}"
release_os="${release_target%-*}"
release_cpu=amd64
[ "$release_arch" != aarch64 ] || release_cpu=arm64
release_nim_flags=(-d:release --threads:on "--cpu:$release_cpu")
case "$release_os" in
  darwin)
    [ "$(uname -s)" = Darwin ] || { echo 'Darwin build requires macOS' >&2; exit 1; }
    release_nim_flags+=(--cc:clang "--passC:-arch $([ "$release_arch" = aarch64 ] && echo arm64 || echo x86_64)" "--passL:-arch $([ "$release_arch" = aarch64 ] && echo arm64 || echo x86_64)")
    ;;
  linux)
    [ "$(uname -s)" = Linux ] || { echo 'Linux build requires Linux' >&2; exit 1; }
    [ "$(uname -m)" = "$release_arch" ] || { echo 'Release must execute on its target architecture' >&2; exit 1; }
    # Zig supplies a versioned glibc sysroot, avoiding the build host's Nix
    # glibc floor. The compiler is supplied by the product's locked dev shell.
    command -v zig >/dev/null
    mkdir -p build/release-toolchain
    release_cc="$(pwd)/build/release-toolchain/cc"
    cat > "$release_cc" <<EOF
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  # Zig accepts the documented -wrap spelling; GNU ld accepts both forms.
  if [[ "\$arg" == -Wl,* ]]; then arg="\${arg//--wrap=/-wrap,}"; fi
  args+=("\$arg")
done
exec "$(command -v zig)" cc -target ${release_arch}-linux-gnu.2.28 "\${args[@]}"
EOF
    chmod +x "$release_cc"
    release_nim_flags+=(--cc:clang "--clang.exe:$release_cc" "--clang.linkerexe:$release_cc")
    ;;
  *) echo "Unsupported target $release_target" >&2; exit 1 ;;
esac
mkdir -p build/bin build/lib test-logs
release_stage="$(pwd)/build/release/$release_target"
rm -rf "$release_stage"
mkdir -p "$release_stage/bin" "$release_stage/lib"
export RELEASE_TARGET="$release_target"

release_finish() {
  "${RELEASE_NODE:-node}" "$RELEASE_TOOLS/payload.cjs" "$release_stage" "$release_target"
}
