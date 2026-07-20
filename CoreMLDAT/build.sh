#!/bin/zsh
# CoreML Detect DAT のビルド → build/CoreMLDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin CoreMLDAT coreml-dat CoreMLDAT.mm -- CoreML Vision CoreVideo
