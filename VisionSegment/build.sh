#!/bin/zsh
# Vision Segment TOP のビルド → build/VisionSegmentTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin VisionSegmentTOP visionsegment-top VisionSegmentTOP.mm -- Vision CoreVideo
