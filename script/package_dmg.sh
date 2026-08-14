#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="USB启动盘工具"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
OUTPUT_DIR="$ROOT_DIR/dist"

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  print -u2 "发布安装包仅支持在 Apple Silicon Mac 上构建。"
  exit 1
fi

"$ROOT_DIR/script/build_and_run.sh" --build-only

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY")"

if [[ "$ARCHITECTURES" != "arm64" ]]; then
  print -u2 "拒绝打包：应用二进制架构为 $ARCHITECTURES，预期为 arm64。"
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

DMG_NAME="USB-Bootable-Drive-Tool-v${VERSION}-macOS-arm64.dmg"
SHA_NAME="$DMG_NAME.sha256"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING_DIR="$(/usr/bin/mktemp -d /private/tmp/usb-maker-dmg.XXXXXX)"

cleanup() {
  if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
    /bin/rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

detach_created_image_if_needed() {
  local image_device
  image_device="$(
    /usr/bin/hdiutil info | /usr/bin/awk -v image_path="$DMG_PATH" '
      /^image-path[[:space:]]*:/ {
        current_path = substr($0, index($0, ": ") + 2)
        matches = (current_path == image_path)
        next
      }
      matches && /^\/dev\/disk[0-9]+[[:space:]]/ {
        print $1
        exit
      }
    '
  )"

  if [[ -n "$image_device" ]]; then
    /usr/bin/hdiutil detach "$image_device"
  fi
}

/bin/mkdir -p "$OUTPUT_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

detach_created_image_if_needed
/usr/bin/hdiutil verify "$DMG_PATH"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" > "$SHA_NAME"
)

print "发布产物：$DMG_PATH"
print "校验文件：$OUTPUT_DIR/$SHA_NAME"
