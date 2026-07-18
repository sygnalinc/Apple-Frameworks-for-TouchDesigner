#!/bin/zsh
# Upscale TOP のビルド → build/UpscaleTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin UpscaleTOP upscale-top UpscaleTOP.mm -- Metal MetalFX VideoToolbox CoreMedia CoreVideo
