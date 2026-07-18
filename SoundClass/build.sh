#!/bin/zsh
# Sound Class CHOP のビルド → build/SoundClassCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin SoundClassCHOP soundclass-chop SoundClassCHOP.mm -- SoundAnalysis AVFAudio CoreML CoreMedia
