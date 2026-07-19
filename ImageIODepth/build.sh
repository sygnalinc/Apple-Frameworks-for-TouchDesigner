#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin ImageIODepthTOP imageiodepth-top ImageIODepthTOP.mm -- ImageIO CoreVideo Accelerate CoreGraphics
