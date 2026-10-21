#!/bin/sh
# Packages the Linux release build as an AppImage that carries what it needs
# beyond a standard desktop: the tray (AppIndicator) libraries, used when the
# system has none, and the notification and alarm sounds. On first launch it
# adds a menu entry, an uninstaller and a watcher that runs the uninstaller
# when the AppImage is deleted.
#
# Run from the repository root after `flutter build linux --release`, on a
# system with libayatana-appindicator3-1 and sound-theme-freedesktop:
#
#   linux/appimage/build-appimage.sh /path/to/appimagetool-x86_64.AppImage
#
# Writes build/appimage/MeshCore_Open-x86_64.AppImage.
set -eu
APPIMAGETOOL="${1:?usage: $0 /path/to/appimagetool}"
SRC="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="build/linux/x64/release/bundle"
OUT="build/appimage"
APPDIR="$OUT/MeshCoreOpen.AppDir"

[ -x "$BUNDLE/meshcore_open" ] || {
  echo "Build first: flutter build linux --release" >&2
  exit 1
}

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/fallback" \
  "$APPDIR/usr/share/sounds" "$APPDIR/usr/share/doc"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
install -m 755 "$SRC/AppRun" "$SRC/integrate.sh" "$SRC/uninstall.sh" "$APPDIR/"
cp web/icons/Icon-512.png "$APPDIR/meshcore-open.png"
cat >"$APPDIR/meshcore-open.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MeshCore Open
Comment=LoRa mesh messaging and emergency SOS
Exec=meshcore_open
Icon=meshcore-open
Terminal=false
Categories=Network;Chat;
EOF

# Copies a package's licence next to what we ship from it.
licence() {
  if [ -f "/usr/share/doc/$1/copyright" ]; then
    mkdir -p "$APPDIR/usr/share/doc/$1"
    cp "/usr/share/doc/$1/copyright" "$APPDIR/usr/share/doc/$1/"
  fi
}

for lib in libayatana-appindicator3.so.1 libayatana-indicator3.so.7 \
  libayatana-ido3-0.4.so.0 libdbusmenu-glib.so.4 libdbusmenu-gtk3.so.4; do
  path="$(/sbin/ldconfig -p | awk -v l="$lib" '$1 == l { print $NF; exit }')"
  [ -n "$path" ] || { echo "Missing $lib on the build system" >&2; exit 1; }
  cp -L "$path" "$APPDIR/usr/lib/fallback/$lib"
  pkg="$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | cut -d: -f1 | head -1)"
  [ -n "$pkg" ] && licence "${pkg%%:*}"
done

for sound in message-new-instant complete alarm-clock-elapsed; do
  cp "/usr/share/sounds/freedesktop/stereo/$sound.oga" "$APPDIR/usr/share/sounds/"
done
licence sound-theme-freedesktop

rm -f "$OUT/MeshCore_Open-x86_64.AppImage"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" \
  "$OUT/MeshCore_Open-x86_64.AppImage"
echo "Built $OUT/MeshCore_Open-x86_64.AppImage"
