#!/bin/zsh
# VisionFace CHOP のビルド → build/VisionFaceCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionFaceCHOP visionface-chop VisionFaceCHOP.mm -- Vision CoreVideo
