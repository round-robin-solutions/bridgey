#!/bin/sh
# Source this before Rust commands: the owned runner isolates HOME, not its installed tools.
BRIDGEY_RUST_TOOL_HOME=${RR_CI_HOST_HOME:-$HOME}
CARGO_HOME=${CARGO_HOME:-$BRIDGEY_RUST_TOOL_HOME/.cargo}
RUSTUP_HOME=${RUSTUP_HOME:-$BRIDGEY_RUST_TOOL_HOME/.rustup}

# Keep an explicit Cargo or an existing PATH choice ahead of the tool-home fallback.
CARGO_BIN=${CARGO:-$(command -v cargo || printf '%s' "$CARGO_HOME/bin/cargo")}
PATH=${PATH:-/usr/bin:/bin}
case ":$PATH:" in
  *":$CARGO_HOME/bin:"*) ;;
  *) PATH="$PATH:$CARGO_HOME/bin" ;;
esac
export CARGO_HOME RUSTUP_HOME PATH

# CI/release packaging requires the connection core. Use the same prerequisite installer as
# build-macos.sh and Android, without changing HOME or replacing an explicit Cargo choice.
bridgey_prepare_macos_rust() {
  BRIDGEY_MAC_RUST_REPO=$1
  BRIDGEY_MAC_RUST_CONFIGURATION=${2:-debug}
  if [ "${BRIDGEY_CONNECT_CORE:-}" = skip ]; then return 0; fi
  if [ "${CI:-}" != 1 ] && [ "$BRIDGEY_MAC_RUST_CONFIGURATION" != release ]; then return 0; fi
  if [ ! -x "$CARGO_BIN" ]; then
    /bin/sh "$BRIDGEY_MAC_RUST_REPO/scripts/rr/rust-toolchain.sh" mac || return $?
    CARGO_BIN=${CARGO:-$(command -v cargo || printf '%s' "$CARGO_HOME/bin/cargo")}
  fi
  if [ ! -x "$CARGO_BIN" ]; then
    echo "error: Rust preparation did not provide executable Cargo for the connection core" >&2
    return 1
  fi
}

if [ -n "${RR_CI_CPU:-}" ]; then
  case "$RR_CI_CPU" in *[!0-9]*) echo "RR_CI_CPU must be a positive integer" >&2; return 2;; esac
  [ "${#RR_CI_CPU}" -le 3 ] && [ "$RR_CI_CPU" -gt 0 ] || { echo "RR_CI_CPU must be a positive integer" >&2; return 2; }
  CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-$RR_CI_CPU}
  export CARGO_BUILD_JOBS
fi
