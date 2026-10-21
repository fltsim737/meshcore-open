#!/bin/sh
# Uninstalls MeshCore Open's desktop integration: the menu entry, start on
# login, the removal watcher and this uninstaller. Your messages, contacts
# and settings are kept, so a newer AppImage picks up where this one left
# off, unless --purge is given.
#
#   uninstall.sh               remove the integration (the AppImage file is
#                              left for you to delete)
#   uninstall.sh --purge       also delete the app's messages, contacts,
#                              settings and caches
#   uninstall.sh --if-missing  only if the AppImage it was installed from no
#                              longer exists (run by the removal watcher)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
STATE="$DATA/meshcore-open"
APP_DATA="$DATA/com.meshcore.meshcore_open"
UNITS="$CONFIG/systemd/user"

if_missing=
purge=
for arg in "$@"; do
  case "$arg" in
    --if-missing) if_missing=1 ;;
    --purge) purge=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ -n "$if_missing" ] && [ -f "$STATE/appimage-path" ]; then
  appimage="$(cat "$STATE/appimage-path")"
  # Still there (or replaced by a newer version): nothing to do.
  [ -e "$appimage" ] && exit 0
fi

# Start on login. Remembered when the data is kept, so opening the AppImage
# again from a new place turns it back on.
if [ -f "$CONFIG/autostart/meshcore-open.desktop" ]; then
  rm -f "$CONFIG/autostart/meshcore-open.desktop"
  if [ -z "$purge" ] && [ -d "$APP_DATA" ]; then
    : >"$APP_DATA/.autostart-was-on"
  fi
fi

rm -f "$DATA/applications/meshcore-open.desktop"
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$DATA/applications" >/dev/null 2>&1

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now meshcore-open-cleanup.path >/dev/null 2>&1
fi
rm -f "$UNITS/meshcore-open-cleanup.path" "$UNITS/meshcore-open-cleanup.service"
command -v systemctl >/dev/null 2>&1 &&
  systemctl --user daemon-reload >/dev/null 2>&1

rm -rf "$STATE"

if [ -n "$purge" ]; then
  rm -rf "$APP_DATA" "$CACHE/com.meshcore.meshcore_open"
  echo "MeshCore Open uninstalled, including its messages and settings."
else
  echo "MeshCore Open uninstalled. Messages and settings are kept in $APP_DATA"
  echo "(run with --purge to delete them too)."
fi
exit 0
