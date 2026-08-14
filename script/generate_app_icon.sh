#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
ASSETS_DIR="$ROOT_DIR/Assets"
MAGICK_BIN="${MAGICK_BIN:-$(command -v magick || true)}"

if [[ -z "$MAGICK_BIN" ]]; then
  print -u2 "需要 ImageMagick 来重新生成 AppIcon.icns。"
  exit 1
fi

WORK_DIR="$(mktemp -d /private/tmp/usb-maker-icon.XXXXXX)"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

"$MAGICK_BIN" -background none "$ASSETS_DIR/AppIcon-background.svg" "$WORK_DIR/background.png"
"$MAGICK_BIN" "$ASSETS_DIR/usb-drive.png" -resize 650x650 "$WORK_DIR/usb.png"
"$MAGICK_BIN" "$WORK_DIR/background.png" \
  "$WORK_DIR/usb.png" -gravity center -geometry +0-8 -composite \
  -strip "$ASSETS_DIR/AppIcon-1024.png"

make_icon() {
  local size="$1"
  local filename="$2"
  "$MAGICK_BIN" "$ASSETS_DIR/AppIcon-1024.png" -filter Lanczos -resize "${size}x${size}" -strip "$ICONSET_DIR/$filename"
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ASSETS_DIR/AppIcon.icns"
print "已生成：$ASSETS_DIR/AppIcon.icns"
