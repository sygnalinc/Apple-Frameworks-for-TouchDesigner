#!/bin/bash
set -e
cd "$(dirname "$0")"
TD_SDK="${TD_SDK:-/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP}"
source ../common/build_plugin.sh
build_td_plugin CoreImageEnhanceTOP coreimageenhance-top CoreImageEnhanceTOP.mm -- CoreImage CoreGraphics
