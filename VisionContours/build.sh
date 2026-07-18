#!/bin/zsh
# Vision Contours SOP build -> build/VisionContoursSOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/SimpleShapesSOP"
source ../common/build_plugin.sh
build_td_plugin VisionContoursSOP visioncontours-sop VisionContoursSOP.mm -- Vision CoreVideo
