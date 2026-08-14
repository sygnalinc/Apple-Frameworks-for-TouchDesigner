#!/bin/zsh
# AFM Core DAT のビルド → build/AFMCoreDAT.plugin
# 2段構成: FMHelper.swift → libFMHelper.dylib、.mm → plugin本体
set -e
cd "$(dirname "$0")"

source ../common/version.sh
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=LLMAFMDAT
DYLIB="libFMHelper_$(date +%s).dylib"
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# ① Swift ヘルパ（FoundationModels は macOS 26 API・@available ガード付きで min 14）
# macOS 27 SDK でだけ AFM3 の新 API(PrivateCloudComputeLanguageModel / Attachment /
# ContextOptions / capabilities / usage)をコンパイルする。**これらは型ごと 26 SDK に無い**ので、
# `if #available` では解決できない(26 機でビルドが通らなくなり実際にリリースが止まった)
SDKVER="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
AFM3=()
if [ "${SDKVER%%.*}" -ge 27 ] 2>/dev/null; then
  AFM3=(-D TD_AFM3)
  echo "SDK $SDKVER: AFM3(macOS 27 API)を有効にしてビルド"
else
  echo "SDK $SDKVER: AFM3(macOS 27 API)は無効(26 SDK には型が無いため)"
fi

swiftc -O -emit-library -module-name FMHelper \
  -target arm64-apple-macos14.0 "${AFM3[@]}" \
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
td_stamp_all
