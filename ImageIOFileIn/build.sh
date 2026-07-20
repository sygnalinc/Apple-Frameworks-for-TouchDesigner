#!/bin/zsh
# ImageIO File In TOP のビルド → build/ImageIOFileInTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin ImageIOFileInTOP imageiofilein-top ImageIOFileInTOP.mm -- ImageIO CoreVideo Accelerate CoreGraphics
