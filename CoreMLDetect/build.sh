#!/bin/zsh
# CoreML Detect DAT のビルド → build/CoreMLDetectDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin CoreMLDetectDAT coremldetect-dat CoreMLDetectDAT.mm -- CoreML Vision CoreVideo
