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
# 图标是 Icon Composer 格式（日间 / 暗色 / 着色由系统切换），要用 Xcode 的 actool 编译
ICON_TMP=$(mktemp -d)
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$ICON_TMP" --app-icon AppIcon \
    --output-partial-info-plist "$ICON_TMP/icon.plist" --minimum-deployment-target 26.0 \
    --platform macosx --target-device mac --errors --warnings >/dev/null
cp "$ICON_TMP/Assets.car" "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_TMP"
# 本机自签名即可运行；分发给别人需要开发者证书和公证
codesign --force --sign - "$APP"
echo "已生成 $(pwd)/$APP"
echo "运行：open $(pwd)/$APP"

# Keep the installed copy current after successful local builds.
if [[ "${1:-}" == "--install" || -d "/Applications/ColorLink.app" ]]; then
    bash ./install-app.sh
fi
