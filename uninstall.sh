#!/bin/bash
# Removes Shotcaller completely. Your screenshots are not touched, and files that
# were already renamed keep their new names.

set -uo pipefail

APP="$HOME/Applications/Shotcaller.app"
AGENT="$HOME/Library/LaunchAgents/com.strider.shotcaller.plist"
SUPPORT="$HOME/Library/Application Support/Shotcaller"

printf '\nRemoving Shotcaller\n\n'

launchctl bootout "gui/$(id -u)/com.strider.shotcaller" 2>/dev/null || \
    launchctl unload -w "$AGENT" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true

rm -f "$AGENT"
rm -rf "$APP"

printf '  App and login item removed.\n\n'
printf 'Your settings and log are still at:\n'
printf '  %s\n\n' "${SUPPORT/#$HOME/~}"
printf 'Delete them too with:\n'
printf '  rm -rf "%s"\n\n' "$SUPPORT"
