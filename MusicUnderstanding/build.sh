#!/bin/zsh
# Music Understanding DAT のビルド → build/MusicUnderstandingDAT.plugin
set -e
cd "$(dirname "$0")"
source ../common/version.sh

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=MusicUnderstandingDAT
DYLIB="libMusicUnderstandingHelper_$(date +%s).dylib"
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"

# MusicUnderstanding は macOS 27+(#available ガード済み)。target は macos15
swiftc -O -emit-library -module-name MusicUnderstandingHelper \
  -target arm64-apple-macos15.0 \
  MusicUnderstandingHelper.swift \
  -Xlinker -weak_framework -Xlinker MusicUnderstanding \
  -framework AVFoundation -framework CoreMedia \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"

clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  MusicUnderstandingDAT.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"

plutil -create xml1 "$OUT/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string $NAME" \
  -c 'Add :CFBundleIdentifier string tokyo.sygnal.musicunderstanding-dat' \
  -c "Add :CFBundleName string $NAME" \
  -c 'Add :CFBundlePackageType string BNDL' \
  -c 'Add :CFBundleVersion string 0.1.0' \
  "$OUT/Info.plist"

codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"
td_stamp_all
