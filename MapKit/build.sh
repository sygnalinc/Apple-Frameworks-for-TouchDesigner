#!/bin/zsh
# 1フォルダ2バンドル(MapKitTOP=スナップショット / MapKitLiveTOP=常駐MKMapView+SCK)。
# 共通ヘルパは rm -rf build を毎回行うため2回呼べない → build_one を手組み(Cinematic と同型)
set -e
cd "$(dirname "$0")"
source ../common/version.sh
SDK_TOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
SDK_DAT="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
rm -rf build

build_one() {
  local NAME="$1" SRC="$2" SUFFIX="$3" SDK="$4"; shift 4
  local OUT="build/$NAME.plugin/Contents"
  local FWKS=()
  for f in "$@"; do FWKS+=(-framework "$f"); done
  # **先にコンパイルして、成功してからバンドルを組む**。逆順だとコンパイル失敗時に
  # 実行ファイルの無い骨格が残り、それをインストールすると TD が起動時にクラッシュする(実際に起きた)
  local TMPBIN="build/.$NAME.tmp"
  mkdir -p build
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" -I "$PYINC" -undefined dynamic_lookup \
    "$SRC" -framework Foundation "${FWKS[@]}" \
    -o "$TMPBIN"
  mkdir -p "$OUT/MacOS"
  mv "$TMPBIN" "$OUT/MacOS/$NAME"
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

build_one MapKitTOP MapKitTOP.mm mapkit-top "$SDK_TOP" \
  MapKit AppKit CoreLocation CoreGraphics ScreenCaptureKit CoreMedia CoreVideo CoreText
build_one MapKitDAT MapKitDAT.mm mapkit-dat "$SDK_DAT" \
  MapKit AppKit CoreLocation
td_stamp_all
