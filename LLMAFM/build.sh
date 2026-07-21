#!/bin/zsh
# AFM Core DAT のビルド → build/AFMCoreDAT.plugin
# 2段構成: FMHelper.swift → libFMHelper.dylib、.mm → plugin本体
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=LLMAFMDAT
DYLIB="libFMHelper_$(date +%s).dylib"
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# ① Swift ヘルパ（FoundationModels は macOS 26 API・@available ガード付きで min 14）
swiftc -O -emit-library -module-name FMHelper \
  -target arm64-apple-macos14.0 \
  helper/FMHelper.swift \
  -framework FoundationModels \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

# ② プラグイン本体
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  LLMAFMDAT.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LLMAFMDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.llmafm-dat</string>
    <key>CFBundleName</key><string>LLMAFMDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
