#!/bin/zsh
set -e
cd "$(dirname "$0")"
# Show UI の閉じるボタンからトグルを戻すのに埋め込み Python を使う（PyCallbacksBootstrap.h）
TD_EXTRA_CFLAGS="-I/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11 -I../common -undefined dynamic_lookup"
export TD_EXTRA_CFLAGS
source ../common/build_plugin.sh
build_td_plugin AudioUnitCHOP audiounit-chop AudioUnitCHOP.mm -- AVFoundation AudioToolbox CoreAudioKit AppKit
