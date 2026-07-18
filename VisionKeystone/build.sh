#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin VisionKeystoneTOP visionkeystone-top VisionKeystoneTOP.mm -- CoreImage CoreVideo CoreGraphics
