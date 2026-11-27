#!/bin/bash
# DiskLens 构建脚本：图标 → 编译 → 打包 .app → 签名 → 可选安装
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/DiskLens.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.0"

echo "▸ 清理"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 生成图标"
mkdir -p "$BUILD/iconout" "$BUILD/AppIcon.iconset"
swiftc -O -sdk "$SDK" -target "$TARGET" "$ROOT/Tools/MakeIcon.swift" -o "$BUILD/makeicon"
"$BUILD/makeicon" "$BUILD/iconout"

copy_icon() { cp "$BUILD/iconout/icon_$1x$1.png" "$BUILD/AppIcon.iconset/$2"; }
copy_icon 16   "icon_16x16.png"
copy_icon 32   "icon_16x16@2x.png"
copy_icon 32   "icon_32x32.png"
copy_icon 64   "icon_32x32@2x.png"
copy_icon 128  "icon_128x128.png"
copy_icon 256  "icon_128x128@2x.png"
copy_icon 256  "icon_256x256.png"
copy_icon 512  "icon_256x256@2x.png"
copy_icon 512  "icon_512x512.png"
copy_icon 1024 "icon_512x512@2x.png"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ 编译应用"
swiftc -O -swift-version 5 -sdk "$SDK" -target "$TARGET" \
    -framework AppKit -framework WebKit -framework CryptoKit -framework QuickLookThumbnailing \
    -framework CoreGraphics -framework ImageIO \
    "$ROOT/Sources/Models.swift" \
    "$ROOT/Sources/Scanner.swift" \
    "$ROOT/Sources/Apps.swift" \
    "$ROOT/Sources/Memory.swift" \
    "$ROOT/Sources/Similar.swift" \
    "$ROOT/Sources/Host.swift" \
    "$ROOT/Sources/Snapshot.swift" \
    "$ROOT/Sources/ScanOnly.swift" \
    "$ROOT/Sources/main.swift" \
    -o "$APP/Contents/MacOS/DiskLens"

echo "▸ 打包资源"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/web"
cp "$ROOT/Resources/web/"* "$APP/Contents/Resources/web/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 签名"
codesign --force --deep --sign - "$APP" 2>&1 | tail -2 || true

echo "▸ 完成: $APP"
du -sh "$APP"

if [ "${1:-}" = "--install" ]; then
    echo "▸ 安装到 /Applications"
    rm -rf "/Applications/DiskLens.app"
    cp -R "$APP" "/Applications/DiskLens.app"
    xattr -dr com.apple.quarantine "/Applications/DiskLens.app" 2>/dev/null || true
    echo "▸ 已安装: /Applications/DiskLens.app"
fi
