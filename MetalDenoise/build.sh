#!/bin/zsh
# Denoise TOP のビルド → build/MetalDenoiseTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin MetalDenoiseTOP metaldenoise-top MetalDenoiseTOP.mm -- VideoToolbox CoreMedia CoreVideo
