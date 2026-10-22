#!/bin/bash
# 编译并打包成 ColorLink.app（菜单栏 App 需要 .app 包才能用通知和蓝牙）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ColorLink
APP=build/ColorLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ColorLink" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 本机自签名即可运行；分发给别人需要开发者证书和公证
codesign --force --sign - "$APP"
echo "已生成 $(pwd)/$APP"
echo "运行：open $(pwd)/$APP"
