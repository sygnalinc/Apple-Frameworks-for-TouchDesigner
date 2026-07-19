#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin SystemAudioCHOP systemaudio-chop SystemAudioCHOP.mm -- ScreenCaptureKit CoreMedia AudioToolbox
