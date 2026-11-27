#!/bin/sh
# Runs a command inside a headless GNOME compositor (Mutter, with XWayland on demand), the way the UI smoke test checks
# what GNOME on Wayland allows: no data-control protocol, so the clipboard goes through XWayland. Usage:
# headless-mutter.sh CMD...
set -eu
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(mktemp -d)}"
chmod 700 "$XDG_RUNTIME_DIR"
mutter --headless --wayland --virtual-monitor 1280x900 > "$XDG_RUNTIME_DIR/mutter.log" 2>&1 &
mutter_pid=$!
for _ in $(seq 1 75); do
  sock=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n 1 || true)
  [ -n "$sock" ] && break
  sleep 0.2
done
[ -n "${sock:-}" ] || { echo "headless-mutter: mutter did not start" >&2; cat "$XDG_RUNTIME_DIR/mutter.log" >&2; exit 1; }
export WAYLAND_DISPLAY="$sock" GDK_BACKEND=wayland
# Mutter starts XWayland when a client connects to the display it advertises.
for _ in $(seq 1 50); do
  d=$(grep -o 'Using public X11 display :[0-9]*' "$XDG_RUNTIME_DIR/mutter.log" | head -n 1 | sed 's/.*://' || true)
  [ -n "$d" ] && break
  sleep 0.2
done
[ -n "${d:-}" ] && export DISPLAY=":$d"
# In a GNOME session gnome-session exports Mutter's XWayland auth file; here we find it ourselves.
auth=$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1 || true)
[ -n "$auth" ] && export XAUTHORITY="$auth"
status=0
"$@" || status=$?
kill "$mutter_pid" 2>/dev/null || true
exit $status
