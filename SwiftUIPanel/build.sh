#!/bin/zsh
# SwiftUI Panel CHOP のビルド → build/SwiftUIPanelCHOP.plugin(Swiftヘルパ同梱)
set -e
cd "$(dirname "$0")"
SDK_CHOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
EPOCH=$(date +%s)
rm -rf build
NAME="SwiftUIPanelCHOP"
OUT="build/$NAME.plugin/Contents"
DYLIB="libSwiftUIPanelHelper_${EPOCH}.dylib"
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name SwiftUIPanelHelper -target arm64-apple-macos13.0 \
  SwiftUIPanelHelper.swift -framework SwiftUI -framework AppKit \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK_CHOP" \
  SwiftUIPanelCHOP.mm -framework Foundation -framework AppKit \
  "$OUT/Frameworks/$DYLIB" -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.swiftuipanel-chop</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($EPOCH)"
