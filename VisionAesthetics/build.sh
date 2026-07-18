#!/bin/zsh
# Vision Aesthetics CHOP のビルド → build/VisionAestheticsCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionAestheticsCHOP visionaesthetics-chop VisionAestheticsCHOP.mm -- Vision CoreVideo
