#!/bin/zsh
set -e
cd "$(dirname "$0")"
SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
NAME=VoiceActivityCHOP
OUT="build/$NAME.plugin/Contents"
rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
mkdir -p build/module-cache
swiftc -O -emit-library -module-name VoiceActivityHelper -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macos14.0 VoiceActivityHelper.swift -framework Speech -framework AVFAudio -framework CoreMedia -Xlinker -install_name -Xlinker @rpath/libVoiceActivityHelper.dylib -o "$OUT/Frameworks/libVoiceActivityHelper.dylib"
clang++ -std=c++17 -fobjc-arc -O2 -bundle -fmodules-cache-path="$PWD/build/module-cache" -I "$SDK" VoiceActivityCHOP.mm -framework Foundation -L "$OUT/Frameworks" -lVoiceActivityHelper -Xlinker -rpath -Xlinker @loader_path/../Frameworks -o "$OUT/MacOS/$NAME"
plutil -create xml1 "$OUT/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string VoiceActivityCHOP' -c 'Add :CFBundleIdentifier string tokyo.sygnal.voiceactivity-chop' -c 'Add :CFBundleName string VoiceActivityCHOP' -c 'Add :CFBundlePackageType string BNDL' -c 'Add :CFBundleVersion string 0.1.0' "$OUT/Info.plist"
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
