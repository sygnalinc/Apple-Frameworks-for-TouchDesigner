#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/SimpleShapesSOP"
source ../common/build_plugin.sh
build_td_plugin ImageIOPointCloudSOP imageiopointcloud-sop ImageIOPointCloudSOP.mm -- ImageIO AVFoundation CoreVideo Accelerate CoreGraphics CoreMedia
