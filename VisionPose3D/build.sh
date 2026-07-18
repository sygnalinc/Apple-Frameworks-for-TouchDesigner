#!/bin/zsh
# Vision Pose 3D CHOP のビルド → build/VisionPose3DCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionPose3DCHOP visionpose3d-chop VisionPose3DCHOP.mm -- Vision CoreVideo
