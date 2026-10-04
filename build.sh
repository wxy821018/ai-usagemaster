#!/bin/bash
# 编译 UsageMaster 并装成 ~/Applications/UsageMaster.app（只在菜单栏显示，不占 Dock）。
# 用法：bash build.sh            只编译安装
#       bash build.sh --login    另外装开机自启（LaunchAgent）
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/UsageMaster.app"
BIN="$APP/Contents/MacOS/UsageMaster"

mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 Sources/*.swift -o "$BIN"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.wxy821018.usagemaster</string>
  <key>CFBundleName</key><string>UsageMaster</string>
  <key>CFBundleExecutable</key><string>UsageMaster</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" || { echo "签名失败"; exit 1; }
echo "已安装：$APP"
# 重启正在跑的实例，让新版本生效
if pgrep -x UsageMaster >/dev/null; then pkill -x UsageMaster || true; sleep 1; open "$APP"; echo "已重启"; fi

if [ "${1:-}" = "--login" ]; then
  PL="$HOME/Library/LaunchAgents/io.github.wxy821018.usagemaster.plist"
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.wxy821018.usagemaster</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/io.github.wxy821018.usagemaster" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PL"
  echo "已设开机自启：$PL（取消：launchctl bootout gui/\$(id -u)/io.github.wxy821018.usagemaster && rm \"$PL\"）"
fi
