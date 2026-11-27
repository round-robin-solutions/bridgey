#!/bin/sh
# Runs a command inside a headless Wayland session (sway with wlroots' headless backend and the pixman renderer), the
# way the UI smoke test checks Wayland and the data-control clipboard without a screen. Usage: headless-sway.sh CMD...
set -eu
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(mktemp -d)}"
chmod 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
config=$(mktemp)
printf 'output HEADLESS-1 resolution 1280x900\n' > "$config"
sway -c "$config" > "$XDG_RUNTIME_DIR/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 1 50); do
  sock=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n 1 || true)
  [ -n "$sock" ] && break
  sleep 0.2
done
[ -n "${sock:-}" ] || { echo "headless-sway: sway did not start" >&2; cat "$XDG_RUNTIME_DIR/sway.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$sock" GDK_BACKEND=wayland
unset DISPLAY
status=0
"$@" || status=$?
kill "$sway_pid" 2>/dev/null || true
exit $status
