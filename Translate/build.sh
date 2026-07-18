#!/bin/zsh
# Translate DAT のビルド → build/TranslateDAT.plugin
# ヘルパ dylib はビルドごとに名前を変える(TDがプラグイン再ロード時に古いdylibを
# 使い回すため。開発中の反復をTD再起動なしで可能にする)
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=TranslateDAT
OUT="build/$NAME.plugin/Contents"
DYLIB="libTrHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name TrHelper \
  -target arm64-apple-macos14.0 \
  helper/TrHelper.swift \
  -framework Translation -framework SwiftUI -framework AppKit \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  TranslateDAT.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TranslateDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.translate-dat</string>
    <key>CFBundleName</key><string>TranslateDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
