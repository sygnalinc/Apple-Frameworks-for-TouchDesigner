#!/bin/zsh
# SAM2 Segment TOP のビルド → build/CoreMLSAM2TOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin CoreMLSAM2TOP coremlsam2-top CoreMLSAM2TOP.mm -- CoreML CoreVideo Accelerate
