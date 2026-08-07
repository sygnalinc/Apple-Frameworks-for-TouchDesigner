#!/bin/zsh
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin SpeechSynthCHOP speechsynth-chop SpeechSynthCHOP.mm -- AVFoundation
