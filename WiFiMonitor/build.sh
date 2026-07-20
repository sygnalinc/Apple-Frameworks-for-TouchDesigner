#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin WiFiMonitorCHOP wifimonitor-chop WiFiMonitorCHOP.mm -- CoreWLAN
