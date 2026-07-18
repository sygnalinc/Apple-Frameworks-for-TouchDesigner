#!/bin/zsh
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionRectCHOP visionrect-chop VisionRectCHOP.mm -- Vision CoreVideo
