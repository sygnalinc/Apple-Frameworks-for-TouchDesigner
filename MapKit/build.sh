#!/bin/zsh
# 1フォルダ2バンドル(MapKitTOP=スナップショット / MapKitLiveTOP=常駐MKMapView+SCK)。
# 共通ヘルパは rm -rf build を毎回行うため2回呼べない → build_one を手組み(Cinematic と同型)
set -e
cd "$(dirname "$0")"
source ../common/version.sh
SDK_TOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
rm -rf build

build_one() {
  local NAME="$1" SRC="$2" SUFFIX="$3"; shift 3
  local OUT="build/$NAME.plugin/Contents"
  mkdir -p "$OUT/MacOS"
  local FWKS=()
  for f in "$@"; do FWKS+=(-framework "$f"); done
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK_TOP" -I "$PYINC" -undefined dynamic_lookup \
    "$SRC" -framework Foundation "${FWKS[@]}" \
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

build_one MapKitTOP MapKitTOP.mm mapkit-top \
  MapKit AppKit CoreLocation CoreGraphics CoreText
build_one MapKitLiveTOP MapKitLiveTOP.mm mapkitlive-top \
  MapKit AppKit CoreLocation CoreGraphics ScreenCaptureKit CoreMedia CoreVideo
td_stamp_all
