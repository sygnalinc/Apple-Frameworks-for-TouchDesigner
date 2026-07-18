#!/bin/zsh
# Denoise TOP のビルド → build/DenoiseTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin DenoiseTOP denoise-top DenoiseTOP.mm -- VideoToolbox CoreMedia CoreVideo
