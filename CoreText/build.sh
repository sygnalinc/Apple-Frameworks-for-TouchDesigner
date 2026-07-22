#!/bin/zsh
# CoreText TOP のビルド → build/CoreTextTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
# Python.h: フォントパネル選択のパラメータ書き戻し用(シンボルは実行時にTD本体から解決)
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
source ../common/build_plugin.sh
build_td_plugin CoreTextTOP coretext-top CoreTextTOP.mm -- CoreText CoreGraphics CoreImage AppKit
