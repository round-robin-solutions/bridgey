#!/bin/sh
# Makes sure the Rust toolchain for the Connect anywhere core (rust/) is there, installing what is
# missing into ~/.cargo with rustup. Every Android and Mac build needs it: without it the apps would
# ship with "Connect away from home: not available".
# Usage: scripts/rr/rust-toolchain.sh android|mac
#   android: stable Rust, targets aarch64-linux-android and x86_64-linux-android, cargo-ndk, and the
#            NDK version the app pins (android/app/build.gradle.kts) when sdkmanager is there.
#   mac:     stable Rust for this Mac.
set -eu
MODE=${1:?usage: rust-toolchain.sh android|mac}
ROOT=$(cd "$(dirname -- "$0")/../.." && pwd)
CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
PATH="$CARGO_HOME/bin:$PATH"
export PATH

if ! command -v rustup >/dev/null 2>&1; then
  echo "rust-toolchain: installing rustup (stable, minimal profile)"
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
fi
rustup toolchain list | grep -q '^stable' || rustup toolchain install stable --profile minimal
case "$MODE" in
  android)
    rustup target add aarch64-linux-android x86_64-linux-android
    command -v cargo-ndk >/dev/null 2>&1 || cargo install cargo-ndk --locked
    NDK_VERSION=$(sed -n 's/^ *ndkVersion = "\(.*\)"/\1/p' "$ROOT/android/app/build.gradle.kts" | head -n 1)
    SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
    if [ -n "$NDK_VERSION" ] && [ ! -d "$SDK/ndk/$NDK_VERSION" ]; then
      SDKMANAGER=$(ls "$SDK"/cmdline-tools/*/bin/sdkmanager 2>/dev/null | sort -V | tail -n 1)
      [ -n "$SDKMANAGER" ] || { echo "rust-toolchain: NDK $NDK_VERSION missing and no sdkmanager under $SDK" >&2; exit 1; }
      yes | "$SDKMANAGER" --install "ndk;$NDK_VERSION" >/dev/null
    fi
    ;;
  mac) ;;
  *) echo "rust-toolchain: unknown mode $MODE" >&2; exit 2 ;;
esac
echo "rust-toolchain: $(rustc --version) ($MODE ready)"
# GitHub Actions: later steps find cargo too.
if [ -n "${GITHUB_PATH:-}" ]; then echo "$CARGO_HOME/bin" >> "$GITHUB_PATH"; fi
