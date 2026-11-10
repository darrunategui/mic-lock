#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || -z "$1" ]]; then
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
DOMAIN="gui/$(id -u)"

mkdir -p "$BIN_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"
swiftc -O "$SCRIPT_DIR/mic-lock.swift" -o "$BIN_DIR/mic-lock" -framework CoreAudio
echo "built $BIN_DIR/mic-lock"

# Stop any running instance and wait for launchd to finish tearing it down,
# otherwise an immediate bootstrap can fail with "Input/output error".
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in {1..50}; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

# Build the plist with plutil rather than a heredoc so that device names
# containing XML special characters (&, <, >) are escaped correctly.
rm -f "$PLIST"
plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -array "$PLIST"
plutil -insert ProgramArguments -string "$BIN_DIR/mic-lock" -append "$PLIST"
plutil -insert ProgramArguments -string "$DEVICE_NAME" -append "$PLIST"
plutil -insert RunAtLoad -bool YES "$PLIST"
plutil -insert KeepAlive -bool YES "$PLIST"
plutil -insert StandardOutPath -string "$LOG" "$PLIST"
plutil -insert StandardErrorPath -string "$LOG" "$PLIST"
plutil -lint -s "$PLIST"

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed and started LaunchAgent $LABEL, watching for device matching \"$DEVICE_NAME\""
echo "logs: $LOG"
