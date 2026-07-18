#!/bin/zsh
# Vision Text DAT のビルド → build/VisionTextDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin VisionTextDAT visiontext-dat VisionTextDAT.mm -- Vision CoreVideo
