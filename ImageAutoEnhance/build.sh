#!/bin/bash
set -e
cd "$(dirname "$0")"
TD_SDK="${TD_SDK:-/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP}"
source ../common/build_plugin.sh
build_td_plugin ImageAutoEnhanceTOP imageautoenhance-top ImageAutoEnhanceTOP.mm -- CoreImage CoreGraphics
