#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin BeaconCHOP beacon-chop BeaconCHOP.mm -- CoreLocation
