#!/bin/zsh
# Upscale TOP のビルド → build/MetalUpscaleTOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
# NC の解像度上限判定に licenses.isNonCommercial を引く（common/NonCommercialLimit.h）。
# シンボルは実行時に TD 本体から解決する。
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
source ../common/build_plugin.sh
build_td_plugin MetalUpscaleTOP metalupscale-top MetalUpscaleTOP.mm -- Metal MetalFX VideoToolbox CoreMedia CoreVideo Accelerate
