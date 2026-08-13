#!/bin/zsh
# Frame Interp TOP のビルド → build/MetalFrameInterpTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin MetalFrameInterpTOP metalframeinterp-top MetalFrameInterpTOP.mm -- VideoToolbox CoreMedia CoreVideo
