#!/bin/zsh
# Speech Text DAT のビルド → build/SpeechTextDAT.plugin
# 2段構成: SpeechHelper.swift → libSpeechHelper.dylib、SpeechTextDAT.mm → plugin本体
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=SpeechTextDAT
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# ① Swift ヘルパ（SpeechAnalyzer は macOS 26 API・@available ガード付きで min 14）
swiftc -O -emit-library -module-name SpeechHelper \
  -target arm64-apple-macos14.0 \
  SpeechHelper.swift \
  -framework Speech -framework AVFAudio \
  -Xlinker -install_name -Xlinker @rpath/libSpeechHelper.dylib \
  -o "$OUT/Frameworks/libSpeechHelper.dylib"

# ② プラグイン本体
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  SpeechTextDAT.mm \
  -framework Foundation \
  -L "$OUT/Frameworks" -lSpeechHelper \
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
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
