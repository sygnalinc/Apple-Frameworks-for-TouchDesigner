#!/bin/zsh
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin PhaseCHOP phase-chop PhaseCHOP.mm -- AVFoundation AudioToolbox CoreAudio PHASE
