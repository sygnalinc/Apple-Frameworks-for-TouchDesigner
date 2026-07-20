#!/bin/zsh
# Cinematic CHOP / TOP を1フォルダから2バンドル生成(共有Swiftヘルパ CinematicHelper を各バンドルに同梱)。
# dylib は epoch 名(TD/dyld の install name キャッシュ対策)。
set -e
cd "$(dirname "$0")"
SDK_CHOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
SDK_TOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
EPOCH=$(date +%s)
rm -rf build

build_one() {
  local NAME="$1" SRC="$2" SDK="$3" SUFFIX="$4"
  local OUT="build/$NAME.plugin/Contents"
  local DYLIB="libCinematicHelper_${EPOCH}.dylib"
  mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
  swiftc -O -emit-library -module-name CinematicHelper -target arm64-apple-macos26.0 \
    CinematicHelper.swift -framework AVFoundation -framework Cinematic -framework Metal -framework Accelerate \
    -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
    -o "$OUT/Frameworks/$DYLIB"
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" \
    "$SRC" -framework Foundation \
    "$OUT/Frameworks/$DYLIB" -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
    -o "$OUT/MacOS/$NAME"
  cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.$SUFFIX</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
  codesign --force --deep -s - "build/$NAME.plugin"
  echo "built: $(pwd)/build/$NAME.plugin"
}

build_one CinematicDataCHOP CinematicDataCHOP.mm "$SDK_CHOP" cinematic-chop
build_one CinematicVideoTOP CinematicVideoTOP.mm  "$SDK_TOP"  cinematic-top
echo "done ($EPOCH)"
