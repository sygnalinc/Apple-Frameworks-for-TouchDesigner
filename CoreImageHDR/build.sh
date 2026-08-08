#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
# NC の解像度上限判定（common/NonCommercialLimit.h が licenses.isNonCommercial を引く）
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
source ../common/build_plugin.sh
build_td_plugin CoreImageHDRTOP coreimagehdr-top CoreImageHDRTOP.mm -- CoreImage CoreGraphics
