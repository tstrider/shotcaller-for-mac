#!/bin/bash
# Builds Shotcaller, installs it, and sets it to start when you log in.
# Safe to run again any time: it replaces what is there and keeps your settings.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Shotcaller.app"
AGENT="$HOME/Library/LaunchAgents/com.strider.shotcaller.plist"
SUPPORT="$HOME/Library/Application Support/Shotcaller"

say() { printf '  %s\n' "$*"; }

printf '\nShotcaller\n\n'

# 1. Check the compiler is there.
if ! command -v swiftc >/dev/null 2>&1; then
    printf 'Swift is not installed.\n\n'
    printf 'Run this, click through the installer, then run this script again:\n\n'
    printf '    xcode-select --install\n\n'
    exit 1
fi

# 2. Stop anything already running.
say "Stopping any running copy"
launchctl bootout "gui/$(id -u)/com.strider.shotcaller" 2>/dev/null || true
pkill -f "Shotcaller.app/Contents/MacOS" 2>/dev/null || true
sleep 1

# 3. Build the app bundle.
say "Building"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$SRC/Resources/Info.plist" "$APP/Contents/Info.plist"

swiftc -O "$SRC/Sources/Shotcaller/main.swift"       -o "$APP/Contents/MacOS/Shotcaller"
swiftc -O "$SRC/Sources/ShotcallerReader/main.swift" -o "$APP/Contents/MacOS/ShotcallerReader"

# Sign locally so macOS gives the app a stable identity. Without this the system
# forgets the folder permission every time the app is rebuilt.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

mkdir -p "$SUPPORT"

# 4. Start it at login.
say "Setting it to start at login"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.strider.shotcaller</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/Shotcaller</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || \
    launchctl load -w "$AGENT" 2>/dev/null || true

sleep 3

# 5. Say what happened.
WHERE=$(defaults read com.apple.screencapture location 2>/dev/null || echo "$HOME/Desktop")
printf '\nInstalled.\n\n'
say "Watching:  ${WHERE/#$HOME/~}"
say "Log:       ~/Library/Application Support/Shotcaller/shotcaller.log"
say "Settings:  ~/Library/Application Support/Shotcaller/config.json"
printf '\n'
printf 'Take a screenshot of something with words in it. Within a few seconds the\n'
printf 'file renames itself after whatever the picture is about.\n\n'
printf 'The first time, macOS may ask whether Shotcaller can read that folder.\n'
printf 'Click Allow. If you miss the box, open System Settings, Privacy and\n'
printf 'Security, Files and Folders, and switch Shotcaller on there.\n\n'
printf 'To remove it completely, run ./uninstall.sh\n\n'
