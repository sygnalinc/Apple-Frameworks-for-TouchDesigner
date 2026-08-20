#!/bin/zsh
# CoreMIDI Out / In CHOP のビルド → build/CoreMIDI{Out,In}CHOP.plugin
#
# 1フォルダから複数バンドルを作る型(Cinematic と同じ)。CoreMIDI In を足すときは
# 末尾に build_one を1行足す。共通ヘルパ(common/build_plugin.sh)は毎回 build/ を消すため
# 2回呼べないので、ここでは使わずに手で組んでいる。
set -e
cd "$(dirname "$0")"
source ../common/version.sh
SDK_CHOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
rm -rf build

build_one() {
  local NAME="$1" SRC="$2" SUFFIX="$3"
  local OUT="build/$NAME.plugin/Contents"
  mkdir -p "$OUT/MacOS"
  # Python.h: CoreMIDI In の Sync to TD Tempo が root.time.tempo を読む
  #(シンボルは実行時に TD 本体から解決するので -undefined dynamic_lookup)
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK_CHOP" -I "$PYINC" -I ../common \
    -undefined dynamic_lookup \
    "$SRC" -framework Foundation -framework CoreMIDI -framework CoreFoundation \
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

build_one CoreMIDIOutCHOP CoreMIDIOutCHOP.mm coremidi-out-chop
build_one CoreMIDIInCHOP  CoreMIDIInCHOP.mm  coremidi-in-chop
td_stamp_all
