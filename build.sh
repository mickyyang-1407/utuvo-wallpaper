#!/bin/bash
# 建立 UTUVO Wallpaper；可從任意來源目錄執行。
#
# 規則：
# - 不安裝到 /Applications、不公證；預設 ad-hoc 簽章，正式發行走 scripts/release.sh。
# - 不開啟 App。
# - 零新 package：只用 swiftc + 系統框架（AppKit / SwiftUI / ImageIO）。
# - 不需要錄螢幕權限：本實驗只用 NSWorkspace 讀寫桌布路徑，不擷取畫面。

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/Sources"
APP="$ROOT/Delivery/UTUVO Wallpaper.app"
EXECUTABLE="WallpaperLab"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

# 可用 SWIFT_VERSION=6 覆寫；預設 5（Swift 6 模式會把主執行緒假設與 actor 隔離檢查打滿）。
SWIFT_VERSION="${SWIFT_VERSION:-5}"
ARCH="$(uname -m)"
DEPLOYMENT_TARGET="14.0"

echo "==> 清理舊 bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> 寫入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>
    <string>com.utuvo.wallpaper-lab</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>UTUVO Wallpaper</string>
    <key>CFBundleDisplayName</key>
    <string>UTUVO Wallpaper</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>${DEPLOYMENT_TARGET}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

cp "$ROOT/Assets/AppIcon.icns" "$RES_DIR/AppIcon.icns"
cp -R "$ROOT/Assets/Demo" "$RES_DIR/Demo"
# 介面語言跟系統：繁中＝原文，其他語言＝英文（Localization/check.py 檢查缺翻譯）。
cp -R "$ROOT/Localization/en.lproj" "$ROOT/Localization/zh-Hant.lproj" "$RES_DIR/"

# ARCHS="arm64 x86_64" 產生 universal；預設只編本機架構。
ARCHS="${ARCHS:-$ARCH}"
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
SLICES=()
for arch in $ARCHS; do
    echo "==> 編譯（swiftc，swift-version ${SWIFT_VERSION}，target ${DEPLOYMENT_TARGET}，${arch}）"
    xcrun -sdk macosx swiftc \
        -O \
        -swift-version "${SWIFT_VERSION}" \
        -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        -framework AppKit \
        -framework SwiftUI \
        -framework ImageIO \
        -framework UniformTypeIdentifiers \
        -framework Security \
        -framework LocalAuthentication \
        "${SRC}"/*.swift \
        -o "${BUILD_TMP}/${EXECUTABLE}-${arch}"
    SLICES+=("${BUILD_TMP}/${EXECUTABLE}-${arch}")
done
xcrun lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${EXECUTABLE}"

# SIGN_IDENTITY 指定 Developer ID 時啟用 hardened runtime＋時間戳（公證必要）；預設 ad-hoc。
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> 簽章：${SIGN_IDENTITY}（hardened runtime）"
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$APP"
else
    echo "==> ad-hoc 簽章（不簽 Developer ID、不公證）"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   （略過簽章）"
fi

echo "==> 完成：$APP"
echo "    執行檔：${MACOS_DIR}/${EXECUTABLE}"
echo "    CLI 自我測試：\"${MACOS_DIR}/${EXECUTABLE}\" --self-test"
