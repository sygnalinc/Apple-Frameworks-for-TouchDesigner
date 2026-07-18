#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
source ../common/build_plugin.sh
build_td_plugin VisionSimilarityCHOP visionsimilarity-chop VisionSimilarityCHOP.mm -- Vision CoreVideo
