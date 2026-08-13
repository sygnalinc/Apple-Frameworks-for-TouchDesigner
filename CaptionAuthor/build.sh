#!/bin/zsh
# Caption Author DAT のビルド → build/CaptionAuthorDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin CaptionAuthorDAT captionauthor-dat CaptionAuthorDAT.mm --
