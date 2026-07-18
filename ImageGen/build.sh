#!/bin/zsh
# Image Gen TOP のビルド → build/ImageGenTOP.plugin
# 2段構成: helper(Swiftパッケージ・ml-stable-diffusion) → libImageGenHelper.dylib、.mm → plugin本体
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
NAME=ImageGenTOP
OUT="build/$NAME.plugin/Contents"

# ① Swift ヘルパ
(cd helper && swift build -c release)

DYLIB="libImageGenHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
cp helper/.build/release/libImageGenHelper.dylib "$OUT/Frameworks/$DYLIB"
install_name_tool -id "@rpath/$DYLIB" "$OUT/Frameworks/$DYLIB"

# ② プラグイン本体（依存dylibはビルド毎に名前を変える=TDのプロセス内キャッシュ対策）
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  ImageGenTOP.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ImageGenTOP</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.imagegen-top</string>
    <key>CFBundleName</key><string>ImageGenTOP</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
