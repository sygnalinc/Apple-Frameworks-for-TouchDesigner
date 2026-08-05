#!/bin/zsh
# RealityKit Splat TOP のビルド → build/RealityKitSplatTOP.plugin
# dylib はビルド毎に名前を変える(TD/dyld が install name でキャッシュするため)
set -e
cd "$(dirname "$0")"
source ../common/version.sh

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
NAME=RealityKitSplatTOP
OUT="build/$NAME.plugin/Contents"
DYLIB="libRealityKitSplatHelper_$(date +%s).dylib"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# GaussianSplatComponent は macOS 27+(#available ガード済み)。ターゲットは macos15 のまま
swiftc -O -emit-library -module-name RealityKitSplatHelper \
  -target arm64-apple-macos15.0 \
  RealityKitSplatHelper.swift \
  -framework RealityKit -framework Metal \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  RealityKitSplatTOP.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

plutil -create xml1 "$OUT/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string $NAME" \
  -c 'Add :CFBundleIdentifier string tokyo.sygnal.realitykitsplat-top' \
  -c "Add :CFBundleName string $NAME" \
  -c 'Add :CFBundlePackageType string BNDL' \
  -c 'Add :CFBundleVersion string 0.1.0' \
  "$OUT/Info.plist"

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
td_stamp_all
