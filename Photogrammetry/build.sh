#!/bin/zsh
# Photogrammetry SOP のビルド → build/PhotogrammetrySOP.plugin
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/SimpleShapesSOP"
NAME=PhotogrammetrySOP
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

swiftc -O -emit-library -module-name PhotogrammetryHelper \
  -target arm64-apple-macos12.0 \
  PhotogrammetryHelper.swift \
  -framework RealityKit \
  -Xlinker -install_name -Xlinker @rpath/libPhotogrammetryHelper.dylib \
  -o "$OUT/Frameworks/libPhotogrammetryHelper.dylib"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  PhotogrammetrySOP.mm \
  -framework Foundation \
  -L "$OUT/Frameworks" -lPhotogrammetryHelper \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhotogrammetrySOP</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.photogrammetry-sop</string>
    <key>CFBundleName</key><string>PhotogrammetrySOP</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
