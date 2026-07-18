#!/bin/zsh
# Vision Flow TOP のビルド → build/VisionFlowTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin VisionFlowTOP visionflow-top VisionFlowTOP.mm -- Vision CoreVideo
