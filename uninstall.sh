#!/bin/zsh
set -euo pipefail

LABEL="com.davidarrunategui.mic-lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$HOME/.local/bin/mic-lock"
echo "uninstalled $LABEL"
