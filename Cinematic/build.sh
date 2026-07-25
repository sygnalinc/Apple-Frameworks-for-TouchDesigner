#!/bin/zsh
# Cinematic Video TOP(旧 Cinematic Data CHOP のメタデータは Info CHOP に統合済み)。
# dylib は epoch 名(TD/dyld の install name キャッシュ対策)。
set -e
cd "$(dirname "$0")"
source ../common/version.sh
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
  # Python.h: Callbacks DAT 自動生成用(シンボルは実行時にTD本体から解決)
  local PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" -I "$PYINC" -undefined dynamic_lookup \
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

build_one CinematicVideoTOP CinematicVideoTOP.mm "$SDK_TOP" cinematic-top
echo "done ($EPOCH)"
td_stamp_all
