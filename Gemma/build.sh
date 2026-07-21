#!/bin/zsh
set -e
cd "$(dirname "$0")"
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=GemmaDAT
DYLIB="libGemmaHelper_$(date +%s).dylib"
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
swiftc -O -emit-library -module-name GemmaHelper -target arm64-apple-macos14.0 helper/GemmaHelper.swift \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" -o "$OUT/Frameworks/$DYLIB"
clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" GemmaDAT.mm -framework Foundation "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks -o "$OUT/MacOS/$NAME"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>GemmaDAT</string><key>CFBundleIdentifier</key><string>tokyo.sygnal.gemma-dat</string><key>CFBundleName</key><string>GemmaDAT</string><key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleVersion</key><string>0.1.0</string></dict></plist>
PLIST
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
