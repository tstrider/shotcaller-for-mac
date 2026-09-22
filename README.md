# Shotcaller for Mac

**Automatically renames your screenshots based on what's in them, so you can find them later.**

Every screenshot you take gets the same useless name: `Screenshot 2026-09-21 at 3.45.12 PM.png`.
Six months later, you can't find the one you need.

Shotcaller looks at each new screenshot, works out what it shows, and names the file after it.
Screen recordings too.

```
Screenshot 2026-09-21 at 10.31.54 PM.png   ->   Discord chat about Spider-Man 2 2026-09-21.png
Screenshot 2026-09-22 at 10.35.00 AM.png   ->   Reddit application creation form 2026-09-22.png
Screenshot 2026-09-22 at 4.23.14 PM.png    ->   Frog meme about PC cleaning 2026-09-22.png
Screen Recording 2026-09-21 at 10.23.10 PM.mov   ->   OBS tutorial 2026-09-21.mov
```

Install it once and forget it. No window, no menu bar icon, no account, no settings. Take a
screenshot, and a few seconds later it has a name Spotlight can find.

Free, open source, and everything happens on your Mac. Built for people with too many
screenshots.

*by Strider*

---

## Install

```bash
git clone https://github.com/tstrider/shotcaller-for-mac.git
cd shotcaller-for-mac
./install.sh
```

That is the whole thing. It builds, installs to `~/Applications`, and starts at login.

**macOS will ask whether Shotcaller can read your screenshot folder. Click Allow.** It has to
ask, because reading your screenshots is the entire job. If you miss the box, open System
Settings, go to Privacy and Security, then Files and Folders, and switch Shotcaller on.

To remove it:

```bash
./uninstall.sh
```

### Requirements

- macOS 13 or newer, Apple silicon or Intel
- For the best names: macOS 26 or later on Apple silicon, with Apple Intelligence switched on
  (System Settings, Apple Intelligence and Siri). macOS 27 lets the model see the picture
  itself; macOS 26 gives it the text only. On Intel, on macOS 13 to 15, or with Apple
  Intelligence off, Shotcaller still works and names each file after its biggest line of text.
- Xcode Command Line Tools, for the Swift compiler. If you do not have them, `install.sh`
  stops and tells you to run `xcode-select --install` first.

There is no prebuilt download, because a prebuilt app has to be notarised by Apple and that
needs a paid developer account. Building from source takes about ten seconds and means you can
read every line before you run it.

---

## How it works

**1. It watches the right folder automatically.** Shotcaller asks macOS where you have chosen
to save screenshots and watches that. Change the location later and it follows, within thirty
seconds, with no restart.

**2. It waits until the file is finished.** A screenshot appears on disk before it is fully
written. Shotcaller only acts once the file size has held steady, so it never reads half a
picture.

**3. It reads the text.** Apple's own on-device text recognition, the same engine behind Live
Text. Nothing is uploaded.

**4. It works out what the screenshot is about.** Apple's on-device language model, the one
behind Apple Intelligence, looks at the picture together with that text and writes a title of
3 to 7 words: the app or site when it is plainly visible, then the subject. A Discord chat
with a Settings window behind it becomes `Discord chat about Spider-Man 2`, not the biggest
word on screen (`4 Energy`, from the Settings sidebar). Only the on-device model is ever used; Shotcaller never calls Apple's cloud one.

The title is then cleaned up for the Finder: no slashes, colons, emoji or stray symbols, no
file extensions read off the screen, no SHOUTING, and never longer than about 60 characters.

**If Apple Intelligence is off,** Shotcaller falls back to scoring every line of text:

- **Size is most of the score.** A heading is a heading because it is large.
- **Lines in the upper half get a small bump.** Titles live at the top.
- **The menu bar strip at the very top gets pushed down.** It is almost never the subject.
- **Interface words are thrown out.** A line that is mostly words like `File`, `Edit`,
  `Cancel`, `Done` never wins, so the macOS menu bar cannot become your filename.
- **Junk is filtered.** Clocks, page numbers, prices, and lines that are mostly digits.

**5. If nothing useful comes back, the file is left alone.** A shot with no readable words at
all, such as a photo or an empty window, keeps the name macOS gave it, because the model would
only invent one. Otherwise Shotcaller tries three times in all, ten minutes apart, before
giving up. It would rather do nothing than give you a bad name.

Recordings are named from a frame about 30% of the way in, never later than 20 seconds.

---

## Two hard-won details

If you are building something similar, these two cost real time to find.

**A background script cannot read your Desktop, Documents or Downloads, and macOS will not
tell you.** An unbundled script gets denied silently: no prompt, no error, and a directory
listing that simply comes back empty. Only a proper app bundle with its own identifier is
allowed to ask for access. That is why Shotcaller ships as a `.app` rather than a shell script
and a launch agent.

**Apple's models take about a minute to load, once.** The first read after a login is slow
enough that it looks like a hang, and every one after it takes a few seconds, because the
loaded models are shared across the whole system. Shotcaller loads it at startup on a
throwaway image, so the first screenshot you actually care about is never the one that waits.

The reading also runs in a separate short-lived process with a time limit. That keeps
a slow or stuck read from stalling the watcher, and means the reader never needs folder
permission of its own, since it is handed a copy in a temporary directory.

---

## Settings

Optional. Lives at `~/Library/Application Support/Shotcaller/config.json` and is re-read every
thirty seconds, so edits take effect without a restart.

| Key | Default | What it does |
|---|---|---|
| `watchFolder` | `""` | Empty follows the macOS screenshot setting. Set a path to override. |
| `keepDate` | `true` | Keeps the date in the new name, so the folder still sorts by time. |
| `useAppleIntelligence` | `true` | Let Apple's on-device model write the name. `false` uses the biggest line of text. |
| `renameRecordings` | `true` | Rename screen recordings too. |
| `prefixes` | many languages | Filename prefixes macOS gives a new screenshot. Only files starting with one of these are ever touched. |
| `recordingPrefixes` | many languages | The same for screen recordings. |

That last one is also the safety catch. Because Shotcaller only ever renames files that still
carry the name macOS gave them, it can never rename one of its own results, and it will not
touch anything else you keep in that folder.

A typo in `config.json` never wipes it: the last good settings stay in use and the log says so.

If your Mac is in a language not on the list, add your prefix to `prefixes` and it will work.
Pull requests adding languages are welcome.

---

## Privacy

Everything happens on your Mac. There is no network code in this project, and the language
model is Apple's on-device one. Nothing is uploaded,
there is no account, and there is no telemetry.

Shotcaller keeps a local log at `~/Library/Application Support/Shotcaller/shotcaller.log` of
what each file was renamed to. That is a list of what your screenshots were about, so only your
user account can read it. It is capped in size, it never leaves your machine, and it is excluded from git.

Shotcaller never deletes a file.

---

## Troubleshooting

**Nothing is happening.** Check the log first:

```bash
tail -20 ~/Library/Application\ Support/Shotcaller/shotcaller.log
```

A line containing `DENIED` means macOS has not granted folder access. Open System Settings,
Privacy and Security, Files and Folders, and switch Shotcaller on.

**It asked for permission again after I updated.** Expected. The app is signed locally, and a
rebuild produces a new signature, which macOS treats as a new app. Click Allow once more.

**The names are not great.** Check that Apple Intelligence is on. A log line ending in
`(from the text)` means the model was not used for that file, and Shotcaller fell back to the
biggest line of text. Even with the model, a busy screenshot can get a vague name; rename those
by hand.

**I want it to stop without uninstalling.**

```bash
launchctl bootout gui/$(id -u)/com.strider.shotcaller
```

It comes back at the next login. To start it again sooner:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.strider.shotcaller.plist
```

---

## License

MIT. See [LICENSE](LICENSE). Do what you like with it.
