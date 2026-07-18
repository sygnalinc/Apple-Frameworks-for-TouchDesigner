#!/bin/zsh
# Vision Pose CHOP のビルド → build/VisionPoseCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionPoseCHOP visionpose-chop VisionPoseCHOP.mm -- Vision CoreVideo
