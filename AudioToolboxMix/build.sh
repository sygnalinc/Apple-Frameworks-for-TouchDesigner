#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin AudioToolboxMixCHOP audiomix-chop AudioToolboxMixCHOP.mm -- AVFoundation AudioToolbox CoreAudio
