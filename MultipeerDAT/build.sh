#!/bin/zsh
# Multipeer In / Out DAT のビルド → build/MultipeerInDAT.plugin, build/MultipeerOutDAT.plugin
set -e
cd "$(dirname "$0")"

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
rm -rf build

build_one() {
    local name="$1" src="$2" suffix="$3"
    local out="build/$name.plugin/Contents"
    mkdir -p "$out/MacOS"
    clang++ -std=c++17 -fobjc-arc -O2 -bundle \
        -I "$SDK" \
        "$src" \
        -framework Foundation -framework MultipeerConnectivity \
        -o "$out/MacOS/$name"
    cat > "$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.$suffix</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
    codesign --force -s - "build/$name.plugin"
    echo "built: $(pwd)/build/$name.plugin"
}

build_one MultipeerInDAT  MultipeerInDAT.mm  multipeerin-dat
build_one MultipeerOutDAT MultipeerOutDAT.mm multipeerout-dat
