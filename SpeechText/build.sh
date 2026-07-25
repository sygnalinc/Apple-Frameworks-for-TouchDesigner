#!/bin/zsh
# Speech Text DAT のビルド → build/SpeechTextDAT.plugin
# 3段構成: SpeechHelper.swift(swiftc直) + whisper/(SPM・WhisperKit) + SpeechTextDAT.mm
# dylib はビルド毎に名前を変える(TD/dyld の install name キャッシュ対策)
set -e
cd "$(dirname "$0")"

source ../common/version.sh
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=SpeechTextDAT
OUT="build/$NAME.plugin/Contents"
EPOCH=$(date +%s)
SPDYLIB="libSpeechHelper_$EPOCH.dylib"
WKDYLIB="libWhisperHelper_$EPOCH.dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# ① SpeechAnalyzer ヘルパ(macOS 26 API・@available ガード付きで min 14)
swiftc -O -emit-library -module-name SpeechHelper \
  -target arm64-apple-macos14.0 \
  SpeechHelper.swift \
  -framework Speech -framework AVFAudio \
  -Xlinker -install_name -Xlinker "@rpath/$SPDYLIB" \
  -o "$OUT/Frameworks/$SPDYLIB"

# ② WhisperKit ヘルパ(SPMパッケージ)
(cd whisper && swift build -c release)
cp whisper/.build/release/libWhisperHelper.dylib "$OUT/Frameworks/$WKDYLIB"
install_name_tool -id "@rpath/$WKDYLIB" "$OUT/Frameworks/$WKDYLIB"

# ③ プラグイン本体
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  SpeechTextDAT.mm \
  -framework Foundation \
  "$OUT/Frameworks/$SPDYLIB" \
  "$OUT/Frameworks/$WKDYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SpeechTextDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.speechtext-dat</string>
    <key>CFBundleName</key><string>SpeechTextDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.2.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($SPDYLIB / $WKDYLIB)"
td_stamp_all
