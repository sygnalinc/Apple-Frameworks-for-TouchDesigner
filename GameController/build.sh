#!/bin/zsh
# Game Controller CHOP のビルド → build/GameControllerCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin GameControllerCHOP gamecontroller-chop GameControllerCHOP.mm -- GameController CoreHaptics
