#!/bin/zsh
# CoreML TOP のビルド → build/CoreMLTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin CoreMLTOP coreml-top CoreMLTOP.mm -- CoreML Vision CoreVideo
