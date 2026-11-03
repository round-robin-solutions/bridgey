#!/bin/sh
# Builds the bridgey agent command for release (docs/agent-cli.md section 11) into dist/cli/:
#   bridgey-<version>-x86_64-unknown-linux-musl.tar.gz    static, rustls with ring, no OpenSSL
#   bridgey-<version>-aarch64-unknown-linux-musl.tar.gz
#   bridgey-<version>-macos-universal.tar.gz              arm64 + x86_64 (lipo), ad-hoc signed; on a Mac only
#   SHA256SUMS and install.sh
# Linux targets use cargo-zigbuild (zig as the C toolchain for ring). Usage:
#   scripts/rr/cli/build-cli.sh [linux|macos|all]     (default: what this machine can build)
# One build per host at a time (AGENTS.md 6.0). Publishing is a separate, approved step (tag cli-v<version>).
set -eu
ROOT=$(cd "$(dirname -- "$0")/../../.." && pwd)
PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export PATH
WHAT=${1:-auto}
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/rust/cli/Cargo.toml" | head -n 1)
OUT="$ROOT/dist/cli"
mkdir -p "$OUT"
cd "$ROOT/rust"

package() { # target, binary path
  dir=$(mktemp -d)
  cp "$2" "$dir/bridgey"
  chmod 755 "$dir/bridgey"
  cp "$ROOT/LICENSE" "$dir/LICENSE"
  cp "$ROOT/docs/agent-cli-setup.md" "$dir/SETUP.md"
  tar -C "$dir" -czf "$OUT/bridgey-$VERSION-$1.tar.gz" bridgey LICENSE SETUP.md
  rm -rf "$dir"
  echo "built $OUT/bridgey-$VERSION-$1.tar.gz"
}

linux() {
  command -v cargo-zigbuild >/dev/null || { echo "build-cli: needs cargo-zigbuild and zig (cargo install cargo-zigbuild --locked)" >&2; exit 1; }
  for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    rustup target add "$target" >/dev/null
    cargo zigbuild --release -p bridgey-cli --target "$target"
    package "$target" "target/$target/release/bridgey"
  done
}

macos() {
  [ "$(uname -s)" = Darwin ] || { echo "build-cli: the macOS build runs on a Mac" >&2; exit 1; }
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target add "$target" >/dev/null
    cargo build --release -p bridgey-cli --target "$target"
  done
  universal=$(mktemp -d)/bridgey
  lipo -create -output "$universal" target/aarch64-apple-darwin/release/bridgey target/x86_64-apple-darwin/release/bridgey
  codesign --force --sign - --identifier in.roundrobin.bridgey.cli "$universal"
  package macos-universal "$universal"
}

case "$WHAT" in
  linux) linux ;;
  macos) macos ;;
  all) linux; macos ;;
  auto) if [ "$(uname -s)" = Darwin ]; then macos; else linux; fi ;;
  *) echo "usage: build-cli.sh [linux|macos|all]" >&2; exit 2 ;;
esac
cp "$ROOT/scripts/rr/cli/install.sh" "$OUT/install.sh"
cd "$OUT"
# Checksums over every tarball present (a Linux run and a Mac run can share dist/cli).
if command -v sha256sum >/dev/null; then sha256sum bridgey-"$VERSION"-*.tar.gz install.sh > SHA256SUMS; else shasum -a 256 bridgey-"$VERSION"-*.tar.gz install.sh > SHA256SUMS; fi
cat SHA256SUMS
