#!/bin/zsh
# CoreWLAN Scan CHOP のビルド → build/CoreWLANScanCHOP.plugin
# SSID取得用のヘルパー .app(独自Info.plist・Location用途文字列)を Contents/Resources/Helpers に同梱。
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
# Python.h（callPythonCallback で Info DAT を自動生成する）。シンボルは実行時に TD 本体から解決。
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
source ../common/build_plugin.sh
build_td_plugin CoreWLANScanCHOP corewlanscan-chop CoreWLANScanCHOP.mm -- CoreWLAN

# --- ヘルパー .app(Location許可+scanForNetworks→JSON) ---
APP="build/CoreWLANScanCHOP.plugin/Contents/Resources/Helpers/wifiscan-helper.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos13.0 helper/wifiscan_helper.swift \
  -framework CoreWLAN -framework CoreLocation -framework Foundation \
  -o "$APP/Contents/MacOS/wifiscan-helper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>wifiscan-helper</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.wifiscan-helper</string>
    <key>CFBundleName</key><string>wifiscan-helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationWhenInUseUsageDescription</key><string>Show nearby Wi-Fi network names (SSID) in TouchDesigner.</string>
    <key>NSLocationUsageDescription</key><string>Show nearby Wi-Fi network names (SSID) in TouchDesigner.</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
# プラグイン全体を再署名(ヘルパー同梱後)
codesign --force --deep -s - "build/CoreWLANScanCHOP.plugin"
echo "bundled wifiscan-helper.app"
