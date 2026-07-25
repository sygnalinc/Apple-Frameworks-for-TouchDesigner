#!/bin/zsh
# Vision Document DAT のビルド → build/VisionDocumentDAT.plugin
# dylib はビルド毎に epoch 名(TD/dyld の install name キャッシュ対策)
set -e
cd "$(dirname "$0")"
source ../common/version.sh
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=VisionDocumentDAT
OUT="build/$NAME.plugin/Contents"
DYLIB="libVisionDocumentHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name VisionDocumentHelper \
  -target arm64-apple-macos26.0 \
  VisionDocumentHelper.swift -framework Vision \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" \
  VisionDocumentDAT.mm -framework Foundation \
  "$OUT/Frameworks/$DYLIB" -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VisionDocumentDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.visiondocument-dat</string>
    <key>CFBundleName</key><string>VisionDocumentDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
td_stamp_all
