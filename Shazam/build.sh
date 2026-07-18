#!/bin/zsh
# Shazam DAT のビルド → build/ShazamDAT.plugin
# 2段構成: ShazamHelper.swift → libShazamHelper.dylib、ShazamDAT.mm → plugin本体
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=ShazamDAT
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name ShazamHelper \
  -target arm64-apple-macos12.0 \
  ShazamHelper.swift \
  -framework ShazamKit -framework AVFAudio \
  -Xlinker -install_name -Xlinker @rpath/libShazamHelper.dylib \
  -o "$OUT/Frameworks/libShazamHelper.dylib"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  ShazamDAT.mm \
  -framework Foundation \
  -L "$OUT/Frameworks" -lShazamHelper \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ShazamDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.shazam-dat</string>
    <key>CFBundleName</key><string>ShazamDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
