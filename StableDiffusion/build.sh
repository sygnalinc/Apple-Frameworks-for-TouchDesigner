#!/bin/zsh
# Stable Diffusion TOP のビルド → build/StableDiffusionTOP.plugin
# 2段構成: helper(Swiftパッケージ・ml-stable-diffusion) → libSDHelper.dylib、.mm → plugin本体
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
NAME=StableDiffusionTOP
OUT="build/$NAME.plugin/Contents"

# ① Swift ヘルパ
(cd helper && swift build -c release)

rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
cp helper/.build/release/libSDHelper.dylib "$OUT/Frameworks/"

# ② プラグイン本体
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  StableDiffusionTOP.mm \
  -framework Foundation \
  -L "$OUT/Frameworks" -lSDHelper \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>StableDiffusionTOP</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.stablediffusion-top</string>
    <key>CFBundleName</key><string>StableDiffusionTOP</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
