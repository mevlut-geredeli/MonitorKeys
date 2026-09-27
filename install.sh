#!/bin/sh
# Builds MonitorKeys, runs the self-test, installs it to ~/Applications and launches it.
set -eu
cd "$(dirname "$0")"
sh build.sh
build/MonitorKeys.app/Contents/MacOS/MonitorKeys --self-test
mkdir -p "$HOME/Applications"
pkill -x MonitorKeys 2>/dev/null && sleep 1 || true
rm -rf "$HOME/Applications/MonitorKeys.app"
ditto build/MonitorKeys.app "$HOME/Applications/MonitorKeys.app"
open "$HOME/Applications/MonitorKeys.app"
echo "Installed and launched ~/Applications/MonitorKeys.app"
echo "Next: allow the system audio prompt, then use the menu bar item → Enable Keyboard Control…"
