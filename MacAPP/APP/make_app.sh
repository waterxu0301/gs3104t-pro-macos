#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release

APPNAME="GS3104T-PRO 键盘助手"
BUNDLE="dist/$APPNAME.app"
rm -rf "dist"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp .build/release/GANSSKeyboard "$BUNDLE/Contents/MacOS/GANSSKeyboard"
cp Resources/rgb-keyboard.xml Resources/config.xml "$BUNDLE/Contents/Resources/"
# 应用图标（icns，由 icon_gen.swift + sips + iconutil 生成）
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>GS3104T-PRO 键盘助手</string>
	<key>CFBundleDisplayName</key><string>GS3104T-PRO 键盘助手</string>
	<key>CFBundleIdentifier</key><string>cn.ganss.gs3104t-pro.helper</string>
	<key>CFBundleVersion</key><string>1.0.0</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleExecutable</key><string>GANSSKeyboard</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSInputMonitoringUsageDescription</key>
	<string>用于读写 GS3104T-PRO 键盘的配置（改键、灯光、宏等）。</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ad-hoc 签名（本机即开即用）
codesign --force --sign - --deep "$BUNDLE" 2>/dev/null || codesign --force --sign - "$BUNDLE"

echo "已生成: $BUNDLE"
