#!/bin/zsh
# Image Metadata DAT のビルド → build/ImageIOMetadataDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin ImageIOMetadataDAT imageiometadata-dat ImageIOMetadataDAT.mm -- ImageIO CoreGraphics
