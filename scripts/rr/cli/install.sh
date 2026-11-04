#!/bin/sh
# Installs the bridgey agent command (Bridgey by Round Robin) for this machine into ~/.local/bin.
#   curl -fsSL https://github.com/round-robin-solutions/bridgey/releases/download/cli-v0.2.0/install.sh | sh
# It downloads the tarball for this OS and CPU from the same release, checks it against the release's
# SHA256SUMS, and installs it. Nothing runs as root. Then: bridgey pair (docs/agent-cli-setup.md).
# BRIDGEY_VERSION=0.2.0 picks a version; BRIDGEY_INSTALL_DIR changes the folder.
set -eu
VERSION=${BRIDGEY_VERSION:-0.2.0}
REPO=round-robin-solutions/bridgey
BASE="https://github.com/$REPO/releases/download/cli-v$VERSION"
DIR=${BRIDGEY_INSTALL_DIR:-$HOME/.local/bin}

case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64|amd64) TARGET=x86_64-unknown-linux-musl ;;
      aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
      *) echo "bridgey: no build for $(uname -m) yet" >&2; exit 1 ;;
    esac ;;
  Darwin) TARGET=macos-universal ;;
  *) echo "bridgey: no build for $(uname -s) yet" >&2; exit 1 ;;
esac

FILE="bridgey-$VERSION-$TARGET.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fetch() { if command -v curl >/dev/null; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }
echo "Downloading $FILE"
fetch "$BASE/$FILE" "$TMP/$FILE"
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
WANT=$(grep " $FILE\$" "$TMP/SHA256SUMS" | cut -d' ' -f1)
[ -n "$WANT" ] || { echo "bridgey: $FILE is not in SHA256SUMS" >&2; exit 1; }
if command -v sha256sum >/dev/null; then GOT=$(sha256sum "$TMP/$FILE" | cut -d' ' -f1); else GOT=$(shasum -a 256 "$TMP/$FILE" | cut -d' ' -f1); fi
[ "$WANT" = "$GOT" ] || { echo "bridgey: checksum mismatch for $FILE; nothing installed" >&2; exit 1; }
tar -xzf "$TMP/$FILE" -C "$TMP"
mkdir -p "$DIR"
install -m 755 "$TMP/bridgey" "$DIR/bridgey"
echo "Installed $DIR/bridgey ($("$DIR/bridgey" --version))"
case ":$PATH:" in *":$DIR:"*) ;; *) echo "Add $DIR to your PATH, for example: echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.profile" ;; esac
echo "Next: bridgey pair"
