#!/bin/zsh
# SAM2 Segment TOP のビルド → build/SAM2SegmentTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin SAM2SegmentTOP sam2segment-top SAM2SegmentTOP.mm -- CoreML CoreVideo Accelerate
