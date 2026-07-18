#!/bin/zsh
# VisionHand CHOP のビルド → build/VisionHandCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionHandCHOP visionhand-chop VisionHandCHOP.mm -- Vision CoreVideo
