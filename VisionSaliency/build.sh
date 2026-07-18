#!/bin/zsh
# Vision Saliency TOP のビルド → build/VisionSaliencyTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin VisionSaliencyTOP visionsaliency-top VisionSaliencyTOP.mm -- Vision CoreVideo
