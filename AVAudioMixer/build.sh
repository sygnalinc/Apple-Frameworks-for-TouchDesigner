#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin AVAudioMixerCHOP spatialmixer-chop AVAudioMixerCHOP.mm -- AVFoundation AudioToolbox CoreAudio
