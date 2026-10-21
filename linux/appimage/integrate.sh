#!/bin/sh
# Installs MeshCore Open's desktop integration for the AppImage at $2 (its
# mounted contents at $1): a menu entry, an uninstaller, and a systemd user
# watcher that runs the uninstaller once the AppImage is deleted. Run by
# AppRun on every launch; only rewrites what changed.
set -e
HERE="$1"
APPIMAGE="$2"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="$DATA/meshcore-open"
APP_DATA="$DATA/com.meshcore.meshcore_open"
UNITS="$CONFIG/systemd/user"

# Writes stdin to $1 if it differs; true (0) when the file changed.
write_if_changed() {
  tmp="$1.tmp.$$"
  cat >"$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$1"
}

# A path in a desktop entry: Exec needs it quoted and escaped, TryExec only
# needs backslashes doubled (desktop entry specification).
exec_path() {
  printf '%s' "$1" | sed -e 's/[\\"`$]/\\&/g' -e 's/\\/\\\\/g' -e 's/%/%%/g' \
    -e 's/^/"/' -e 's/$/"/'
}
plain_path() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g'
}
# A path in a systemd unit: % and $ are special there.
unit_path() {
  printf '%s' "$1" | sed -e 's/%/%%/g' -e 's/\$/$$/g'
}

mkdir -p "$STATE" "$DATA/applications"
cp -f "$HERE/uninstall.sh" "$STATE/uninstall.sh"
chmod 755 "$STATE/uninstall.sh"
cp -f "$HERE/meshcore-open.png" "$STATE/icon.png"
printf '%s\n' "$APPIMAGE" | write_if_changed "$STATE/appimage-path" || true

if write_if_changed "$DATA/applications/meshcore-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MeshCore Open
Comment=LoRa mesh messaging and emergency SOS
Exec=$(exec_path "$APPIMAGE")
TryExec=$(plain_path "$APPIMAGE")
Icon=$(plain_path "$STATE/icon.png")
Terminal=false
Categories=Network;Chat;
StartupWMClass=com.meshcore.meshcore_open
EOF
then
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$DATA/applications" || true
fi

# Start on login was on before the AppImage moved: put it back. The app
# itself manages the entry from then on.
if [ -f "$APP_DATA/.autostart-was-on" ]; then
  mkdir -p "$CONFIG/autostart"
  cat >"$CONFIG/autostart/meshcore-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MeshCore Open
Comment=Listens for messages and SOS alerts
TryExec=$(plain_path "$APPIMAGE")
Exec=$(exec_path "$APPIMAGE") --hidden
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  rm -f "$APP_DATA/.autostart-was-on"
fi

# Removal watcher (systemd user session only).
command -v systemctl >/dev/null 2>&1 || exit 0
systemctl --user show-environment >/dev/null 2>&1 || exit 0
mkdir -p "$UNITS"
changed=
write_if_changed "$UNITS/meshcore-open-cleanup.path" <<EOF && changed=1
[Unit]
Description=Remove MeshCore Open's desktop integration when its AppImage is deleted

[Path]
PathChanged=$(unit_path "$APPIMAGE")
Unit=meshcore-open-cleanup.service

[Install]
WantedBy=default.target
EOF
write_if_changed "$UNITS/meshcore-open-cleanup.service" <<EOF && changed=1
[Unit]
Description=Remove MeshCore Open's desktop integration if its AppImage is gone

[Service]
Type=oneshot
ExecStart=/bin/sh "$(unit_path "$STATE/uninstall.sh")" --if-missing
EOF
if [ -n "$changed" ] || ! systemctl --user is-active --quiet meshcore-open-cleanup.path; then
  systemctl --user daemon-reload
  systemctl --user enable meshcore-open-cleanup.path >/dev/null 2>&1
  systemctl --user restart meshcore-open-cleanup.path
fi
