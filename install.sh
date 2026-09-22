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

# 2. Build the app bundle somewhere private first, so a failed build leaves the
#    copy that is already installed running untouched.
say "Building"
BUILD="$(mktemp -d)/Shotcaller.app"
trap 'rm -rf "$(dirname "$BUILD")"' EXIT
mkdir -p "$BUILD/Contents/MacOS"
cp "$SRC/Resources/Info.plist" "$BUILD/Contents/Info.plist"

# Built to run on macOS 13 and later. Apple's language model is linked weakly, so
# on a Mac without it Shotcaller still runs and names files from their text.
TARGET="$(uname -m)-apple-macos13.0"
swiftc -O -target "$TARGET" "$SRC/Sources/Shotcaller/main.swift" \
    -o "$BUILD/Contents/MacOS/Shotcaller"
swiftc -O -target "$TARGET" "$SRC/Sources/ShotcallerReader/main.swift" \
    -Xlinker -weak_framework -Xlinker FoundationModels \
    -o "$BUILD/Contents/MacOS/ShotcallerReader"

# Sign locally so macOS gives the app a stable identity. The helper is signed
# first, then the app around it.
codesign --force --sign - --identifier com.strider.shotcaller.reader \
    "$BUILD/Contents/MacOS/ShotcallerReader" >/dev/null
codesign --force --sign - "$BUILD" >/dev/null

# 3. Swap it in.
say "Stopping any running copy"
launchctl bootout "gui/$(id -u)/com.strider.shotcaller" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
sleep 1
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$BUILD" "$APP"

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"

# 4. Start it at login.
say "Setting it to start at login"
mkdir -p "$HOME/Library/LaunchAgents"
# The path goes into XML, so characters XML treats as special are escaped.
APP_XML=$(printf '%s' "$APP/Contents/MacOS/Shotcaller" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.strider.shotcaller</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_XML</string>
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
printf 'Take a screenshot. Within a few seconds the file renames itself after\n'
printf 'whatever the picture is about.\n\n'
printf 'The best names come from Apple Intelligence, which runs on your Mac. If it is\n'
printf 'off, Shotcaller names each file after its biggest line of text instead. Turn it\n'
printf 'on in System Settings, Apple Intelligence and Siri.\n\n'
printf 'The first time, macOS may ask whether Shotcaller can read that folder.\n'
printf 'Click Allow. If you miss the box, open System Settings, Privacy and\n'
printf 'Security, Files and Folders, and switch Shotcaller on there.\n\n'
printf 'To remove it completely, run ./uninstall.sh\n\n'
