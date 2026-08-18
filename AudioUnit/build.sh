#!/bin/zsh
# 1フォルダから2バンドル(AudioUnit Effect / AudioUnit Instrument)。
# 共通ヘルパ build_td_plugin は毎回 build/ を消すので2回呼べない → 手組み(Cinematic と同じ型)。
set -e
cd "$(dirname "$0")"
source ../common/version.sh
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
# Python.h: パネル生成・パラメータ書き戻し用(シンボルは実行時に TD 本体から解決)
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
rm -rf build

build_one() {
  local NAME="$1" SRC="$2" SUFFIX="$3"
  local OUT="build/$NAME.plugin/Contents"
  mkdir -p "$OUT/MacOS"
  # **先にコンパイルしてから**バンドルを組む(失敗時に実行ファイルの無い骨格を残さない)
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" -I "$PYINC" -I ../common \
    -undefined dynamic_lookup "$SRC" \
    -framework Foundation -framework AVFoundation -framework AudioToolbox \
    -framework CoreAudioKit -framework AppKit \
    -o "/tmp/$NAME.$$"
  mv "/tmp/$NAME.$$" "$OUT/MacOS/$NAME"
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

build_one AudioUnitEffectCHOP     AudioUnitEffectCHOP.mm     audiounit-effect-chop
build_one AudioUnitInstrumentCHOP AudioUnitInstrumentCHOP.mm audiounit-instrument-chop
td_stamp_all
