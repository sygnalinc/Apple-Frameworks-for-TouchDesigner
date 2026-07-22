#!/bin/zsh
# PDFKit TOP(旧 PDFKit DAT の構造テーブルは Info DAT に統合済み)。
set -e
cd "$(dirname "$0")"
SDK_TOP="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
rm -rf build
build_one() {
  local NAME="$1" SRC="$2" SDK="$3" SUFFIX="$4"
  local OUT="build/$NAME.plugin/Contents"; mkdir -p "$OUT/MacOS"
  clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" -I "/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11" -undefined dynamic_lookup "$SRC" \
    -framework Foundation -framework PDFKit -framework CoreGraphics -framework AppKit -o "$OUT/MacOS/$NAME"
  cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>tokyo.sygnal.$SUFFIX</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
  codesign --force --deep -s - "build/$NAME.plugin"
  echo "built: $(pwd)/build/$NAME.plugin"
}
build_one PDFKitTOP PDFKitTOP.mm "$SDK_TOP" pdfkit-top
