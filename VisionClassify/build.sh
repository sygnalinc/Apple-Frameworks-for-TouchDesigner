#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin VisionClassifyDAT visionclassify-dat VisionClassifyDAT.mm -- Vision CoreVideo
