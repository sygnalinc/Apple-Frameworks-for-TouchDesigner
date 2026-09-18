#!/bin/zsh
# CoreAI TOP のビルド → build/CoreAITOP.plugin
# dylib はビルド毎に名前を変える(TD/dyld が install name でキャッシュするため)
set -e
cd "$(dirname "$0")"
source ../common/version.sh

SDK="${TD_APP:-/Applications/TouchDesigner.app}/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
NAME=CoreAITOP
OUT="build/$NAME.plugin/Contents"
DYLIB="libCoreAIHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# CoreAI framework は macOS 27 で追加。26 でもロードできるよう -weak_framework でリンクし、
# Swift 側は全て @available(macOS 27.0, *) の裏(26 では status に理由を返すだけ)。
# SDK 27 が無い環境(macOS 26 機)では canImport(CoreAI) が偽になり、同じ「unavailable」経路になる
swiftc -O -emit-library -module-name CoreAIHelper \
  -target arm64-apple-macos26.0 \
  CoreAIHelper.swift \
  -Xlinker -weak_framework -Xlinker CoreAI \
  -framework CoreGraphics -framework CoreVideo \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  CoreAITOP.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

plutil -create xml1 "$OUT/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string $NAME" \
  -c 'Add :CFBundleIdentifier string tokyo.sygnal.coreai-top' \
  -c "Add :CFBundleName string $NAME" \
  -c 'Add :CFBundlePackageType string BNDL' \
  -c 'Add :CFBundleVersion string 0.1.0' \
  "$OUT/Info.plist"

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
td_stamp_all
