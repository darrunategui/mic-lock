#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: ./install.sh \"<substring of your input device's name>\"" >&2
  echo "        run 'system_profiler SPAudioDataType' to see exact device names first" >&2
  exit 1
fi

DEVICE_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LABEL="com.davidarrunategui.mic-lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mic-lock.log"

mkdir -p "$BIN_DIR"
swiftc -O "$SCRIPT_DIR/mic-lock.swift" -o "$BIN_DIR/mic-lock" -framework CoreAudio
echo "built $BIN_DIR/mic-lock"

launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/mic-lock</string>
    <string>$DEVICE_NAME</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF

launchctl load "$PLIST"
echo "installed and started LaunchAgent $LABEL, watching for device matching \"$DEVICE_NAME\""
echo "logs: $LOG"
