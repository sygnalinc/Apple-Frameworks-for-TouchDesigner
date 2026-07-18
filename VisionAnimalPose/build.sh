#!/bin/zsh
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin VisionAnimalPoseCHOP visionanimalpose-chop VisionAnimalPoseCHOP.mm -- Vision CoreVideo
