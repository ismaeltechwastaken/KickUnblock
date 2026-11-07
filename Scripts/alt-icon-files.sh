#!/bin/bash
set -euo pipefail
APP="${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}"
PLIST="$APP/Info.plist"
PB=/usr/libexec/PlistBuddy
NAMES="${ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES:-AppIcon-OLED AppIcon-Inverted AppIcon-Electric AppIcon-Crimson AppIcon-Gold AppIcon-MonoLight}"
[ -f "$PLIST" ] || { echo "error: no Info.plist at $PLIST"; exit 1; }

set_files() {
  local dict="$1" name="$2"; shift 2
  local base=":$dict:CFBundleAlternateIcons:$name"
  $PB -c "Print $base" "$PLIST" >/dev/null 2>&1 || {
    $PB -c "Add $base dict" "$PLIST"
    $PB -c "Add $base:CFBundleIconName string $name" "$PLIST"
  }
  $PB -c "Delete $base:CFBundleIconFiles" "$PLIST" >/dev/null 2>&1 || true
  $PB -c "Add $base:CFBundleIconFiles array" "$PLIST"
  local i=0
  for f in "$@"; do $PB -c "Add $base:CFBundleIconFiles:$i string $f" "$PLIST"; i=$((i + 1)); done
}

for name in $NAMES; do
  for f in "${name}60x60@2x.png" "${name}60x60@3x.png" "${name}76x76@2x~ipad.png" "${name}83.5x83.5@2x~ipad.png"; do
    [ -f "$APP/$f" ] || { echo "error: loose icon $f missing from the app bundle"; exit 1; }
  done
  set_files CFBundleIcons "$name" "${name}60x60@3x.png" "${name}60x60"
  $PB -c "Print :CFBundleIcons~ipad" "$PLIST" >/dev/null 2>&1 || $PB -c "Add :CFBundleIcons~ipad dict" "$PLIST"
  $PB -c "Print :CFBundleIcons~ipad:CFBundleAlternateIcons" "$PLIST" >/dev/null 2>&1 || $PB -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons dict" "$PLIST"
  set_files "CFBundleIcons~ipad" "$name" "${name}83.5x83.5@2x~ipad.png" "${name}60x60" "${name}76x76" "${name}83.5x83.5"
done
if [ -f "$APP/AppIcon60x60@3x.png" ]; then
  P=":CFBundleIcons:CFBundlePrimaryIcon"
  $PB -c "Delete $P:CFBundleIconFiles" "$PLIST" >/dev/null 2>&1 || true
  $PB -c "Add $P:CFBundleIconFiles array" "$PLIST"
  $PB -c "Add $P:CFBundleIconFiles:0 string AppIcon60x60@3x.png" "$PLIST"
  $PB -c "Add $P:CFBundleIconFiles:1 string AppIcon60x60" "$PLIST"
  $PB -c "Print $P:CFBundleIconName" "$PLIST" >/dev/null 2>&1 || $PB -c "Add $P:CFBundleIconName string AppIcon" "$PLIST"
  $PB -c "Print :CFBundleIconName" "$PLIST" >/dev/null 2>&1 || $PB -c "Add :CFBundleIconName string AppIcon" "$PLIST"
  echo "primary CFBundleIconFiles set"
else
  echo "warning: no loose AppIcon60x60@3x.png; primary icon left as actool wrote it"
fi
echo "CFBundleIconFiles added for: $NAMES"
