#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_BUNDLE="$ROOT_DIR/USB启动盘工具.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ICON_FILE="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

zsh -n "$ROOT_DIR/build.command"
zsh -n "$ROOT_DIR/script/build_and_run.sh"
zsh -n "$ROOT_DIR/script/generate_app_icon.sh"
zsh -n "$ROOT_DIR/script/package_dmg.sh"

if /usr/bin/xcrun --find swift-format >/dev/null 2>&1; then
  /usr/bin/xcrun swift-format lint --strict "$ROOT_DIR/Sources/USBBootableDriveTool/main.swift"
fi

/usr/bin/swiftc \
  -typecheck \
  -parse-as-library \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  "$ROOT_DIR/Sources/USBBootableDriveTool/main.swift"

! /usr/bin/grep -q 'NSWorkspace.shared.open(script)' "$ROOT_DIR/Sources/USBBootableDriveTool/main.swift"
! /usr/bin/grep -q '/usr/bin/sudo' "$ROOT_DIR/Sources/USBBootableDriveTool/main.swift"

"$ROOT_DIR/script/build_and_run.sh" --build-only
/usr/bin/plutil -lint "$INFO_PLIST"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ICON_CHECK_DIR="$(mktemp -d /private/tmp/usb-maker-icon-check.XXXXXX)"
/usr/bin/iconutil -c iconset "$ICON_FILE" -o "$ICON_CHECK_DIR/AppIcon.iconset"
[[ -f "$ICON_CHECK_DIR/AppIcon.iconset/icon_16x16.png" ]]
[[ -f "$ICON_CHECK_DIR/AppIcon.iconset/icon_512x512@2x.png" ]]

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" diff --check
fi

print "全部非破坏性检查通过。"
