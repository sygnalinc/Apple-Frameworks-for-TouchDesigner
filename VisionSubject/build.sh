#!/bin/zsh
# Vision Subject TOP のビルド → build/VisionSubjectTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin VisionSubjectTOP visionsubject-top VisionSubjectTOP.mm -- Vision CoreVideo
