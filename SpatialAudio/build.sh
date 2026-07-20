#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin SpatialAudioCHOP spatialaudio-chop SpatialAudioCHOP.mm -- AVFoundation AudioToolbox CoreAudio
