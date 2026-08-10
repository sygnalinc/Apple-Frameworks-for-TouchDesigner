#!/bin/zsh
# Sound Class CHOP のビルド → build/SoundClassCHOP.plugin
cd "$(dirname "$0")"
TD_EXTRA_CFLAGS="-I /Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11 -undefined dynamic_lookup"
source ../common/build_plugin.sh
build_td_plugin SoundClassCHOP soundclass-chop SoundClassCHOP.mm -- SoundAnalysis AVFAudio CoreML CoreMedia
