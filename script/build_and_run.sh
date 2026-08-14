#!/bin/zsh
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="${0:A:h:h}"
APP_NAME="USB启动盘工具"
BUNDLE_ID="cn.fanny7d.usb-maker"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
APP_BINARY="$MACOS/$APP_NAME"
INFO_PLIST="$CONTENTS/Info.plist"

stop_running_app() {
  local app_pid
  app_pid="$(pgrep -x "$APP_NAME" | head -1 || true)"
  if [[ -n "$app_pid" ]]; then
    kill -TERM "$app_pid"
    for _ in {1..20}; do
      pgrep -x "$APP_NAME" >/dev/null || return 0
      sleep 0.1
    done
    print -u2 "无法停止正在运行的 $APP_NAME（PID $app_pid）。"
    exit 1
  fi
}

build_app() {
  mkdir -p "$MACOS" "$RESOURCES"
  /usr/bin/swiftc \
    -parse-as-library \
    -framework AppKit \
    -framework Foundation \
    -o "$APP_BINARY" \
    "$ROOT_DIR/Sources/USBBootableDriveTool/main.swift"

  /bin/cp "$ROOT_DIR/Assets/usb-drive.png" "$RESOURCES/usb-drive.png"
  /bin/cp "$ROOT_DIR/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"

  /usr/bin/plutil -create xml1 "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.1.0 "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleVersion -string 2 "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleIconFile -string AppIcon.icns "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleIconName -string AppIcon "$INFO_PLIST"
  /usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.utilities "$INFO_PLIST"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$INFO_PLIST"
  /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
  /usr/bin/plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert CFBundleDevelopmentRegion -string zh_CN "$INFO_PLIST"
  /usr/bin/plutil -insert NSHumanReadableCopyright -string "Copyright © 2026 fanny7d. MIT License." "$INFO_PLIST"

  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
  /usr/bin/touch "$APP_BUNDLE"
  print "构建完成：$APP_BUNDLE"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_app
build_app

case "$MODE" in
  --build-only|build)
    print "构建验证完成，未启动应用。"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    app_pid="$(pgrep -x "$APP_NAME" | head -1 || true)"
    [[ -n "$app_pid" ]]
    print "运行验证通过：$APP_NAME (PID $app_pid)"
    ;;
  *)
    print -u2 "用法：$0 [run|--build-only|--debug|--logs|--telemetry|--verify]"
    exit 2
    ;;
esac
