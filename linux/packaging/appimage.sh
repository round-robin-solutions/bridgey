#!/bin/sh
# Packs a release build of Bridgey for Linux into an AppImage that carries GTK 4, libadwaita and what they need, so it
# runs on any desktop with glibc 2.39 or later (Ubuntu 24.04, Fedora 40, Debian 13 and newer), GNOME or not.
#
#   linux/packaging/appimage.sh BINARY OUTPUT.AppImage
#
# Run it on the oldest system the AppImage supports (linux/build/Dockerfile, Ubuntu 24.04): the libraries it copies
# come from there. Left to the host, as AppImage's own exclude list does: glibc, the graphics drivers (GL, EGL, Vulkan,
# DRM), libX11 and libxcb, fontconfig, FreeType and HarfBuzz, zlib, expat, libgcc and libstdc++.
#
# The AppImage runtime is the pinned type2-runtime release below, checked by SHA-256 before use.
set -eu

BIN=$1
OUT=$2
ROOT=$(cd "$(dirname -- "$0")/../.." && pwd)
ARCH=$(uname -m)
RUNTIME_RELEASE=20251108
case "$ARCH" in
  x86_64) RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64) RUNTIME_SHA256=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
  *) echo "appimage: no runtime for $ARCH" >&2; exit 2 ;;
esac
MULTIARCH=$(gcc -print-multiarch 2>/dev/null || dpkg-architecture -qDEB_HOST_MULTIARCH)
LIBDIR=/usr/lib/$MULTIARCH

CACHE=${BRIDGEY_APPIMAGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bridgey-appimage}
mkdir -p "$CACHE"
RUNTIME="$CACHE/runtime-$ARCH-$RUNTIME_RELEASE"
if [ ! -f "$RUNTIME" ] || [ "$(sha256sum "$RUNTIME" | cut -d' ' -f1)" != "$RUNTIME_SHA256" ]; then
  curl -fsSL --retry 3 -o "$RUNTIME.part" "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_RELEASE/runtime-$ARCH"
  got=$(sha256sum "$RUNTIME.part" | cut -d' ' -f1)
  if [ "$got" != "$RUNTIME_SHA256" ]; then
    echo "appimage: the runtime's SHA-256 is $got, expected $RUNTIME_SHA256" >&2
    rm -f "$RUNTIME.part"
    exit 1
  fi
  mv "$RUNTIME.part" "$RUNTIME"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/bridgey" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/metainfo" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" "$APPDIR/usr/share/glib-2.0/schemas" "$APPDIR/usr/lib/gdk-pixbuf/loaders"

install -m 755 "$BIN" "$APPDIR/usr/bin/bridgey-linux"
cp -r "$ROOT/linux/data/icons" "$ROOT/linux/data/fonts" "$APPDIR/usr/share/bridgey/"
cp "$ROOT/linux/data/in.roundrobin.bridgey.metainfo.xml" "$APPDIR/usr/share/metainfo/"
cp "$ROOT/linux/data/icons/hicolor/scalable/apps/in.roundrobin.bridgey.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/"
cp "$ROOT/linux/data/icons/hicolor/scalable/apps/in.roundrobin.bridgey.svg" "$APPDIR/in.roundrobin.bridgey.svg"
rsvg-convert -w 256 -h 256 "$APPDIR/in.roundrobin.bridgey.svg" -o "$APPDIR/.DirIcon"
cp "$ROOT/LICENSE" "$APPDIR/usr/share/bridgey/LICENSE"
cp "$ROOT/NOTICE" "$APPDIR/usr/share/bridgey/NOTICE"

# The symbolic icons Bridgey and GTK use, from GNOME's Adwaita theme (CC BY-SA 3.0 or LGPL 3), so desktops with
# another icon theme (KDE's Breeze, Xfce's) still show every one.
for name in $(grep -rhoE '"[a-z-]+-symbolic"' "$ROOT/linux/src" | tr -d '"' | sort -u) \
  window-close-symbolic window-maximize-symbolic window-minimize-symbolic window-restore-symbolic system-search-symbolic \
  edit-find-symbolic go-previous-symbolic pan-down-symbolic pan-end-symbolic pan-start-symbolic document-edit-symbolic \
  object-select-symbolic edit-clear-symbolic edit-copy-symbolic folder-symbolic user-home-symbolic; do
  src=$(find /usr/share/icons/Adwaita/symbolic -name "$name.svg" | head -n 1)
  [ -n "$src" ] && cp "$src" "$APPDIR/usr/share/bridgey/icons/"
done
cp /usr/share/doc/adwaita-icon-theme/copyright "$APPDIR/usr/share/bridgey/icons/ADWAITA-COPYRIGHT" 2>/dev/null || true

cat > "$APPDIR/in.roundrobin.bridgey.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Bridgey by Round Robin
Comment=Clipboard, files and notifications between your phone and this computer
Comment[ru]=Буфер обмена, файлы и уведомления между телефоном и этим компьютером
Exec=bridgey-linux %F
Icon=in.roundrobin.bridgey
Terminal=false
Categories=Network;Utility;
StartupWMClass=in.roundrobin.bridgey
X-AppImage-Name=Bridgey by Round Robin
EOF
cp "$APPDIR/in.roundrobin.bridgey.desktop" "$APPDIR/usr/share/applications/"

# GTK's own settings schemas (the file chooser reads them).
cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.gschema.xml "$APPDIR/usr/share/glib-2.0/schemas/"
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# The SVG image loader (icons) and its cache, whose paths AppRun fills in at start.
cp "$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so" "$APPDIR/usr/lib/gdk-pixbuf/loaders/"
QUERY=$(command -v gdk-pixbuf-query-loaders || echo "$LIBDIR/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders")
"$QUERY" "$APPDIR/usr/lib/gdk-pixbuf/loaders/libpixbufloader-svg.so" > "$WORK/loaders.cache"
sed "s|$APPDIR|@APPDIR@|g" "$WORK/loaders.cache" > "$APPDIR/usr/lib/gdk-pixbuf/loaders.cache.in"
grep -q 'image/svg' "$APPDIR/usr/lib/gdk-pixbuf/loaders.cache.in" || { echo "appimage: the SVG loader did not register" >&2; exit 1; }

excluded() {
  case "$1" in
    ld-linux*|libc.so.*|libdl.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libnsl.so.*|libanl.so.*|libBrokenLocale.so.*|libthread_db.so.*) return 0 ;;
    libgcc_s.so.*|libstdc++.so.*) return 0 ;;
    libGL.so.*|libEGL.so.*|libGLX*|libGLdispatch.so.*|libOpenGL.so.*|libGLESv2.so.*|libdrm.so.*|libgbm.so.*|libvulkan.so.*) return 0 ;;
    libX11.so.*|libX11-xcb.so.*|libxcb.so.*) return 0 ;;
    libfontconfig.so.*|libfreetype.so.*|libharfbuzz.so.*|libexpat.so.*|libz.so.*|libuuid.so.*) return 0 ;;
  esac
  return 1
}

# Every library the binary and the loader need, and theirs, less the exclusions.
copy_deps() {
  ldd "$1" | awk '/=> \// { print $3 }' | while read -r lib; do
    base=$(basename "$lib")
    excluded "$base" && continue
    [ -f "$APPDIR/usr/lib/$base" ] && continue
    cp -L "$lib" "$APPDIR/usr/lib/$base"
    chmod 644 "$APPDIR/usr/lib/$base"
  done
}
copy_deps "$APPDIR/usr/bin/bridgey-linux"
copy_deps "$APPDIR/usr/lib/gdk-pixbuf/loaders/libpixbufloader-svg.so"

# No LD_LIBRARY_PATH (it would leak into the browser or file manager Bridgey opens): the binary looks in usr/lib
# through its RPATH, which also covers its libraries' own dependencies, and each copied library looks beside itself.
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$APPDIR/usr/bin/bridgey-linux"
for lib in "$APPDIR"/usr/lib/*.so*; do
  patchelf --force-rpath --set-rpath '$ORIGIN' "$lib"
done
patchelf --force-rpath --set-rpath '$ORIGIN/../..' "$APPDIR/usr/lib/gdk-pixbuf/loaders/libpixbufloader-svg.so"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# Bridgey's AppImage launcher. It changes only what it must, and keeps the desktop's values (BRIDGEY_ORIG_<NAME>,
# BRIDGEY_UNSET_<NAME>) so the apps Bridgey opens get them back.
HERE=$(dirname "$(readlink -f "$0")")
for name in GDK_PIXBUF_MODULE_FILE XDG_DATA_DIRS; do
  if eval "[ -n \"\${$name+x}\" ]"; then eval "export BRIDGEY_ORIG_$name=\"\$$name\""; else export "BRIDGEY_UNSET_$name=1"; fi
done
export BRIDGEY_APPIMAGE_ENV="GDK_PIXBUF_MODULE_FILE XDG_DATA_DIRS"
dir=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
cache="$dir/bridgey-pixbuf-$(printf '%s' "$HERE" | cksum | cut -d' ' -f1).cache"
sed "s|@APPDIR@|$HERE|g" "$HERE/usr/lib/gdk-pixbuf/loaders.cache.in" > "$cache" 2>/dev/null && export GDK_PIXBUF_MODULE_FILE="$cache"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/bridgey-linux" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

mksquashfs "$APPDIR" "$WORK/app.squashfs" -root-owned -noappend -comp zstd -Xcompression-level 15 -quiet >/dev/null
cat "$RUNTIME" "$WORK/app.squashfs" > "$OUT.part"
chmod 755 "$OUT.part"
mv "$OUT.part" "$OUT"
echo "appimage: $OUT ($(du -h "$OUT" | cut -f1), $(ls "$APPDIR/usr/lib" | grep -c '\.so') libraries)"
