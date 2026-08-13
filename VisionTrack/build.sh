#!/bin/zsh
# Vision Track CHOP のビルド → build/VisionTrackCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionTrackCHOP visiontrack-chop VisionTrackCHOP.mm -- Vision CoreVideo
