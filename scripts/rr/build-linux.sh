#!/bin/sh
# Builds and tests Bridgey by Round Robin for Linux: the RR CI `linux` lane runs this (ci/rr-ci-linux-task.json).
#
#   scripts/rr/build-linux.sh                 every check, the UI smoke tests and the AppImage
#   scripts/rr/build-linux.sh --container     the same inside linux/build/Dockerfile (Ubuntu 24.04), for hosts without
#                                             the GTK packages (rr-dev-2, owned workers)
#   scripts/rr/build-linux.sh --quick         no Wayland pass and English light only (a second architecture)
#
# Steps: the session client's tests (rust/client, the library the app links), the app's clippy and unit tests, a
# release build, the UI smoke tests under Xvfb (X11, English and Russian, light and dark, self-update) and headless
# sway (Wayland, the data-control clipboard), the AppImage, a start of the AppImage itself, and SHA256SUMS.
#
# Versions come from rr-edition.properties: BRIDGEY_VERSION_NAME and BRIDGEY_BUILD_NUMBER when a release sets them,
# else <next>-dev and the UTC build time (YYDDDHHMM), as build-windows.ps1.
#
# Output in linux/out: Bridgey-RR-<version>-linux-<arch>.AppImage, SHA256SUMS, screenshots/, logs/.
set -eu
ROOT=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

QUICK=0
CONTAINER=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --container) CONTAINER=1 ;;
    *) echo "build-linux: unknown option $a" >&2; exit 2 ;;
  esac
done

if [ "$CONTAINER" = 1 ]; then
  docker build -q -t bridgey-linux-build:24.04 linux/build >/dev/null
  cache=${BRIDGEY_LINUX_CARGO_CACHE:-$HOME/.cache/bridgey-linux-cargo-registry}
  mkdir -p "$cache"
  args=""
  [ "$QUICK" = 1 ] && args="--quick"
  exec docker run --rm -i ${BRIDGEY_LINUX_DOCKER_CPUS:+--cpus "$BRIDGEY_LINUX_DOCKER_CPUS"} -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -e BRIDGEY_VERSION_NAME="${BRIDGEY_VERSION_NAME:-}" -e BRIDGEY_BUILD_NUMBER="${BRIDGEY_BUILD_NUMBER:-}" -e CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-}" \
    -v "$ROOT:/src" -v "$cache:/opt/cargo/registry" -w /src bridgey-linux-build:24.04 sh scripts/rr/build-linux.sh $args
fi

step() { printf '\n== %s\n' "$*"; }

# GitHub's hosted Ubuntu runners: install the packages the image has.
if [ "${GITHUB_ACTIONS:-}" = true ] || [ "${RR_CI_HOSTED:-}" = 1 ]; then
  if ! pkg-config --exists gtk4 libadwaita-1 2>/dev/null; then
    step "Packages"
    sudo apt-get update -qq
    xargs -a linux/build/packages.txt sudo apt-get install -y -qq --no-install-recommends >/dev/null
  fi
  command -v cargo >/dev/null 2>&1 || sh scripts/rr/rust-toolchain.sh mac
  if [ -n "${GITHUB_PATH:-}" ] && [ -d "$HOME/.cargo/bin" ]; then PATH="$HOME/.cargo/bin:$PATH"; export PATH; fi
fi
. scripts/rr/rust-env.sh
CARGO=${CARGO_BIN:-cargo}
export CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0
ulimit -c 0 2>/dev/null || true

prefix=$(sed -n 's/^EDITION_ASSET_PREFIX=//p' rr-edition.properties)
next=$(sed -n 's/^EDITION_NEXT_VERSION=//p' rr-edition.properties)
export BRIDGEY_VERSION_NAME="${BRIDGEY_VERSION_NAME:-$next-dev}"
export BRIDGEY_BUILD_NUMBER="${BRIDGEY_BUILD_NUMBER:-$(date -u +%y%j%H%M)}"
ARCH=$(uname -m)
OUT="$ROOT/linux/out"
rm -rf "$OUT"
mkdir -p "$OUT/screenshots" "$OUT/logs"
echo "Bridgey for Linux $BRIDGEY_VERSION_NAME, build $BRIDGEY_BUILD_NUMBER, $ARCH ($(. /etc/os-release && echo "$PRETTY_NAME"), GTK $(pkg-config --modversion gtk4), libadwaita $(pkg-config --modversion libadwaita-1))"

logged() {
  name=$1
  shift
  if ! "$@" > "$OUT/logs/$name.log" 2>&1; then
    tail -n 80 "$OUT/logs/$name.log" >&2
    echo "build-linux: $name failed (log: linux/out/logs/$name.log)" >&2
    exit 1
  fi
  tail -n 3 "$OUT/logs/$name.log"
}

step "Session client tests (rust/client)"
logged rust-client "$CARGO" test --locked --manifest-path rust/Cargo.toml -p bridgey-client

step "Linux app: clippy and unit tests"
logged linux-clippy "$CARGO" clippy --locked --manifest-path linux/Cargo.toml --all-targets -- -D warnings
logged linux-tests "$CARGO" test --locked --manifest-path linux/Cargo.toml

step "Release build and the scripted peer"
logged linux-release "$CARGO" build --locked --release --manifest-path linux/Cargo.toml
logged peer "$CARGO" build --locked --manifest-path rust/Cargo.toml -p bridgey-client --example peer
APP="$ROOT/linux/target/release/bridgey-linux"
PEER="$ROOT/rust/target/debug/examples/peer"

# The UI tests and their helpers (a notification server, a media player, the AT-SPI probe) need GObject
# introspection, which the distribution's Python has (python3-gi) and a CI-provided Python (actions/setup-python on
# hosted runners) does not. Use the first Python that can import gi.
UI_PY=python3
for p in /usr/bin/python3 python3; do
  if "$p" -c 'import gi' 2>/dev/null; then UI_PY=$p; break; fi
done

step "UI smoke tests: X11 (Xvfb)"
if [ "$QUICK" = 1 ]; then langs=en themes=light; else langs=en,ru themes=light,dark; fi
logged ui-x11 dbus-run-session -- xvfb-run -a -s "-screen 0 1280x900x24" "$UI_PY" linux/tests/ui_smoke.py --app "$APP" --peer "$PEER" \
  --out "$OUT/screenshots/x11" --langs "$langs" --themes "$themes" --expect-clipboard X11

if [ "$QUICK" = 0 ]; then
  step "UI smoke tests: Wayland (headless sway, data-control)"
  logged ui-wayland dbus-run-session -- linux/tests/headless-sway.sh "$UI_PY" linux/tests/ui_smoke.py --wayland --expect-clipboard DataControl \
    --app "$APP" --peer "$PEER" --out "$OUT/screenshots/wayland" --langs en --themes light,dark --skip-update --port 42710
fi

step "AppImage"
IMAGE="$OUT/$prefix-$BRIDGEY_VERSION_NAME-linux-$ARCH.AppImage"
logged appimage sh linux/packaging/appimage.sh "$APP" "$IMAGE"
# The AppImage itself starts (unpacked, as on a system without FUSE) and draws its window with its own libraries.
APPIMAGE_EXTRACT_AND_RUN=1 "$IMAGE" --version
logged appimage-ui dbus-run-session -- xvfb-run -a -s "-screen 0 1280x900x24" "$UI_PY" linux/tests/appimage_smoke.py "$IMAGE" "$OUT/screenshots/appimage-$ARCH.png"

(cd "$OUT" && sha256sum ./*.AppImage | sed 's| \./| |' > SHA256SUMS)
cat "$OUT/SHA256SUMS"
echo "build-linux: done"
