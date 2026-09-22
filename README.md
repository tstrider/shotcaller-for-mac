# Shotcaller for Mac

**by Strider**

Your screenshots are all called `Screenshot 2026-09-21 at 3.45.12 PM.png`. Six months later
you cannot find a single one of them.

Shotcaller reads the words in each new screenshot and renames the file after whatever the
picture is actually about.

```
Screenshot 2026-09-21 at 3.45.12 PM.png   ->   Order shipped and on its way 2026-09-21.png
Screenshot 2026-09-21 at 4.02.55 PM.png   ->   Monthly savings plan 2026-09-21.png
Screenshot 2026-09-21 at 4.20.11 PM.png   ->   left alone, nothing readable in it
```

It runs quietly in the background. No window, no menu bar icon, no account, no settings to
learn. You take a screenshot and a few seconds later the file has a name you can search for.

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

**4. It picks the title.** This is the part that matters, and it is why a generic "extract text
and rename" script does not work. Raw text extraction hands you the whole wall of words, and
you end up with filenames like `Safari File Edit View History Your order has shipped Track`.

Shotcaller scores every line instead:

- **Size is most of the score.** A heading is a heading because it is large.
- **Lines in the upper half get a small bump.** Titles live at the top.
- **The menu bar strip at the very top gets pushed down.** It is almost never the subject.
- **Interface words are thrown out.** A line that is mostly words like `File`, `Edit`,
  `Cancel`, `Done` never wins, so the macOS menu bar cannot become your filename.
- **Junk is filtered.** Clocks, page numbers, prices, and lines that are mostly digits.

The highest scoring line becomes the name. If the winner is short and the runner up sits right
under it in the same size, the two are joined, because headings wrap.

**5. If nothing readable comes back, the file is left alone.** A screenshot of a photo, a map,
or an empty window keeps the name macOS gave it. Shotcaller would rather do nothing than give
you a bad name.

---

## Two hard-won details

If you are building something similar, these two cost real time to find.

**A background script cannot read your Desktop, Documents or Downloads, and macOS will not
tell you.** An unbundled script gets denied silently: no prompt, no error, and a directory
listing that simply comes back empty. Only a proper app bundle with its own identifier is
allowed to ask for access. That is why Shotcaller ships as a `.app` rather than a shell script
and a launch agent.

**Apple's text model takes about a minute to load, once.** The first recognition after a login
is slow enough that it looks like a hang, and every one after it takes under a second, because
the loaded model is shared across the whole system. Shotcaller loads it at startup on a
throwaway image, so the first screenshot you actually care about is never the one that waits.

The text recognition also runs in a separate short-lived process with a time limit. That keeps
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
| `prefixes` | ten languages | Filename prefixes macOS gives a new screenshot. Only files starting with one of these are ever touched. |

That last one is also the safety catch. Because Shotcaller only ever renames files that still
carry the name macOS gave them, it can never rename one of its own results, and it will not
touch anything else you keep in that folder.

If your Mac is in a language not on the list, add your prefix to `prefixes` and it will work.
Pull requests adding languages are welcome.

---

## Privacy

Everything happens on your Mac. There is no network code in this project. Nothing is uploaded,
there is no account, and there is no telemetry.

Shotcaller keeps a local log at `~/Library/Application Support/Shotcaller/shotcaller.log` of
what each file was renamed to. That is a list of what your screenshots were about, so treat it
as private. It is capped in size, it never leaves your machine, and it is excluded from git.

Shotcaller never deletes a file.

---

## Troubleshooting

**Nothing is happening.** Check the log first:

```bash
tail -20 ~/Library/Application\ Support/Shotcaller/shotcaller.log
```

A line starting `DENIED` means macOS has not granted folder access. Open System Settings,
Privacy and Security, Files and Folders, and switch Shotcaller on.

**It asked for permission again after I updated.** Expected. The app is signed locally, and a
rebuild produces a new signature, which macOS treats as a new app. Click Allow once more.

**The names are not great on some screenshots.** Shotcaller is picking the largest text. On a
screenshot with no clear heading there is no good answer, and it will either pick something
mediocre or leave the file alone. Rename those by hand.

**I want it to stop without uninstalling.**

```bash
launchctl bootout gui/$(id -u)/com.strider.shotcaller
```

---

## License

MIT. See [LICENSE](LICENSE). Do what you like with it.
