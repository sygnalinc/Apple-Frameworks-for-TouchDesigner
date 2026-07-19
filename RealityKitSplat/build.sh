#!/bin/zsh
# RealityKit Splat TOP のビルド → build/RealityKitSplatTOP.plugin
# dylib はビルド毎に名前を変える(TD/dyld が install name でキャッシュするため)
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
NAME=RealityKitSplatTOP
OUT="build/$NAME.plugin/Contents"
DYLIB="libRealityKitSplatHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name RealityKitSplatHelper \
  -target arm64-apple-macos15.0 \
  RealityKitSplatHelper.swift \
  -framework RealityKit -framework Metal \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  RealityKitSplatTOP.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>RealityKitSplatTOP</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.realitykitsplat-top</string>
    <key>CFBundleName</key><string>RealityKitSplatTOP</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
