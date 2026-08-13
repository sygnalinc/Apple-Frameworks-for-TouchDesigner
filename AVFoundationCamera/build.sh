#!/bin/zsh
# AVF Camera TOP のビルド → build/AVFCameraTOP.plugin
set -e
cd "$(dirname "$0")"
# NonCommercialLimit.h が TD 組み込み Python を使う(NC の解像度上限判定)
PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin AVFCameraTOP avf-camera-top AVFCameraTOP.mm -- AVFoundation CoreMedia CoreVideo
