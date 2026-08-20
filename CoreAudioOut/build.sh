#!/bin/zsh
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin CoreAudioOutCHOP coreaudioout-chop CoreAudioOutCHOP.mm -- CoreAudio AudioToolbox
