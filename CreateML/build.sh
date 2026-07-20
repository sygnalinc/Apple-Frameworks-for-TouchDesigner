#!/bin/zsh
# CreateML DAT(汎用トレーナ)のビルド → build/CreateMLDAT.plugin
# dylib は epoch 名(TD/dyld の install name キャッシュ対策)
set -e
cd "$(dirname "$0")"
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=CreateMLDAT
OUT="build/$NAME.plugin/Contents"
DYLIB="libCreateMLHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name CreateMLHelper \
  -target arm64-apple-macos14.0 \
  CreateMLHelper.swift -framework CreateML \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" \
  CreateMLDAT.mm -framework Foundation \
  "$OUT/Frameworks/$DYLIB" -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CreateMLDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.createml-dat</string>
    <key>CFBundleName</key><string>CreateMLDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
