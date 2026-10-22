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
# Writes build/appimage/<APP_NAME with underscores>-x86_64.AppImage.
#
# APP_NAME, APP_SLUG (file names of the menu entry, autostart entry and
# watcher) and APP_ID (linux/CMakeLists.txt's APPLICATION_ID, which also
# names the data folder) keep two builds' desktop integration apart. The
# scripts use MeshCore Open's names and are adjusted as they are copied.
set -eu
APPIMAGETOOL="${1:?usage: $0 /path/to/appimagetool}"
APP_NAME="${APP_NAME:-MeshCore Open SOS Voice}"
APP_SLUG="${APP_SLUG:-meshcore-open-sos-voice}"
APP_ID="${APP_ID:-com.meshcore.meshcore_open_voice}"
SRC="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="build/linux/x64/release/bundle"
OUT="build/appimage"
APPDIR="$OUT/MeshCoreOpen.AppDir"
APPIMAGE_FILE="$OUT/$(printf '%s' "$APP_NAME" | tr ' ' _)-x86_64.AppImage"

[ -x "$BUNDLE/meshcore_open" ] || {
  echo "Build first: flutter build linux --release" >&2
  exit 1
}

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/fallback" \
  "$APPDIR/usr/share/sounds" "$APPDIR/usr/share/doc"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
for script in AppRun integrate.sh uninstall.sh; do
  sed -e "s/com\.meshcore\.meshcore_open/$APP_ID/g" \
    -e "s/MeshCore Open/$APP_NAME/g" -e "s/meshcore-open/$APP_SLUG/g" \
    "$SRC/$script" >"$APPDIR/$script"
  chmod 755 "$APPDIR/$script"
done
cp web/icons/Icon-512.png "$APPDIR/$APP_SLUG.png"
cat >"$APPDIR/$APP_SLUG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=LoRa mesh messaging and emergency SOS
Exec=meshcore_open
Icon=$APP_SLUG
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

rm -f "$APPIMAGE_FILE"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" \
  "$APPIMAGE_FILE"
echo "Built $APPIMAGE_FILE"
