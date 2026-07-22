#!/bin/zsh
# CoreText TOP のビルド → build/CoreTextTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin CoreTextTOP coretext-top CoreTextTOP.mm -- CoreText CoreGraphics CoreImage
