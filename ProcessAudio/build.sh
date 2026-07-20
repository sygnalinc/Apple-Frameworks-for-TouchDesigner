#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin ProcessAudioCHOP processaudio-chop ProcessAudioCHOP.mm -- CoreAudio AudioToolbox
