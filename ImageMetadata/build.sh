#!/bin/zsh
# Image Metadata DAT のビルド → build/ImageMetadataDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin ImageMetadataDAT imagemetadata-dat ImageMetadataDAT.mm -- ImageIO CoreGraphics
