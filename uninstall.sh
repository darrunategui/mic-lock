#!/bin/zsh
set -euo pipefail

LABEL="com.davidarrunategui.mic-lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$HOME/.local/bin/mic-lock"
echo "uninstalled $LABEL"
