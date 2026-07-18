#!/bin/zsh
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionTrajectoryCHOP visiontrajectory-chop VisionTrajectoryCHOP.mm -- Vision CoreVideo CoreMedia
