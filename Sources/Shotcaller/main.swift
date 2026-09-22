// Shotcaller
//
// Watches your screenshot folder and renames each new screenshot after the text
// inside it, so "Screenshot 2026-09-21 at 3.45.12 PM.png" becomes
// "Quarterly revenue by region 2026-09-21.png".
//
// Two things here exist for reasons that are not obvious:
//
// 1. This ships as an app bundle rather than a plain background script. macOS
//    refuses an unbundled script any access to Desktop, Documents and Downloads,
//    and denies it silently, with no prompt and no error. A bundled app with its
//    own identifier is allowed to ask, so the usual access box appears instead.
//
// 2. The text recognition happens in a separate helper process with a time limit.
//    Apple's text model takes around a minute to load the first time after a login
//    and is fast after that, so Shotcaller loads it on a throwaway image at startup.
//    Keeping the reader separate means a slow or stuck read can never stop the
//    watcher, and the reader never needs folder permission of its own.
//
// Shotcaller never deletes anything. A file it cannot read a sensible title out of
// keeps the name macOS gave it.

import Foundation

// MARK: - settings

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Shotcaller")
let logFile = supportDir.appendingPathComponent("shotcaller.log")
let configFile = supportDir.appendingPathComponent("config.json")
let reader = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ShotcallerReader")

struct Config: Codable {
    /// Folder to watch. Empty means "ask macOS where screenshots go".
    var watchFolder: String = ""
    /// Keep the date in the new filename, so the folder still sorts by when.
    var keepDate: Bool = true
    /// Filename prefixes macOS uses for a fresh screenshot, per language. Only files
    /// starting with one of these are ever touched, which is also what stops a file
    /// Shotcaller has already renamed from being picked up a second time.
    var prefixes: [String] = [
        "screenshot", "screen shot",        // English
        "bildschirmfoto",                   // German
        "captura de pantalla",              // Spanish
        "capture d'écran", "capture d’écran", // French
        "schermafbeelding",                 // Dutch
        "skärmavbild",                      // Swedish
        "zrzut ekranu",                     // Polish
        "снимок экрана",                    // Russian
        "스크린샷",                            // Korean
        "スクリーンショット"                      // Japanese
    ]
}

func loadConfig() -> Config {
    if let data = try? Data(contentsOf: configFile),
       let parsed = try? JSONDecoder().decode(Config.self, from: data) {
        return parsed
    }
    let fresh = Config()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(fresh) { try? data.write(to: configFile) }
    return fresh
}

/// Where macOS is currently told to put screenshots. Falls back to the Desktop,
/// which is the factory default.
func screenshotFolder(_ config: Config) -> URL {
    if !config.watchFolder.isEmpty {
        return URL(fileURLWithPath: (config.watchFolder as NSString).expandingTildeInPath)
    }
    if let defaults = UserDefaults(suiteName: "com.apple.screencapture"),
       let location = defaults.string(forKey: "location"), !location.isEmpty {
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }
    return home.appendingPathComponent("Desktop")
}

// MARK: - log

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(stamp.string(from: Date()))  \(message)\n"
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logFile)
    }
    // Keep the log from growing without limit.
    if let size = try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int, size > 512_000 {
        if let text = try? String(contentsOf: logFile, encoding: .utf8) {
            let kept = text.split(separator: "\n").suffix(500).joined(separator: "\n")
            try? (kept + "\n").write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - asking the reader what the picture says

func title(for url: URL) -> String? {
    // Copy to a scratch file first, so the reader never touches a protected folder
    // and needs no permission of its own.
    let scratch = fm.temporaryDirectory
        .appendingPathComponent("shotcaller-\(UUID().uuidString).\(url.pathExtension)")
    guard let data = try? Data(contentsOf: url), (try? data.write(to: scratch)) != nil else {
        return nil
    }
    defer { try? fm.removeItem(at: scratch) }

    let task = Process()
    task.executableURL = reader
    task.arguments = [scratch.path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do { try task.run() } catch {
        log("ERROR  could not start the reader: \(error.localizedDescription)")
        return nil
    }

    // A wedged reader must never wedge the watcher. The limit is generous because a
    // cold model load genuinely can take a minute; anything past that is stuck.
    let started = Date()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { task.waitUntilExit(); finished.signal() }
    if finished.wait(timeout: .now() + 180) == .timedOut {
        task.terminate()
        log("ERROR  the reader timed out on \(url.lastPathComponent), will try again later")
        timedOut.insert(url.lastPathComponent)
        return nil
    }
    let seconds = Date().timeIntervalSince(started)
    if seconds > 10 { log("SLOW   read took \(Int(seconds))s, the text model was cold") }

    guard task.terminationStatus == 0,
          let out = try? pipe.fileHandleForReading.readToEnd(),
          let text = String(data: out, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          text.count >= 4
    else { return nil }

    return text
}

// MARK: - the rename pass

var config = loadConfig()
var watchDir = screenshotFolder(config)
var sizeSeen: [String: Int] = [:]   // sizes between passes, so half written files are left alone
var skipped: Set<String> = []       // files the reader could not name, so we stop retrying
var timedOut: Set<String> = []      // files that ran out of time, which are worth another go
var deniedLogged = false

let work = DispatchQueue(label: "com.strider.shotcaller.work", qos: .utility)

// The folder tells us when it changes, so there is no busy polling. A slow sweep
// runs underneath it as a backstop, and also catches the screenshot folder being
// moved in System Settings while Shotcaller is running.
var vnode: DispatchSourceFileSystemObject?

// Always called on `work`. Opening the folder blocks for as long as the macOS
// permission box is unanswered, so it must never run on the main thread.
func watchFolderForChanges() {
    vnode?.cancel()
    let fd = open(watchDir.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: work)
    source.setEventHandler {
        // Give the writer a moment to finish before looking.
        work.asyncAfter(deadline: .now() + 0.7) { autoreleasepool { pass() } }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    vnode = source
}


func isFreshScreenshot(_ name: String) -> Bool {
    let lower = name.lowercased()
    guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    else { return false }
    return config.prefixes.contains { lower.hasPrefix($0) }
}

func pass() {
    let names: [String]
    do {
        names = try fm.contentsOfDirectory(atPath: watchDir.path)
        if deniedLogged {
            log("ACCESS restored, the folder is readable again")
            deniedLogged = false
        }
    } catch {
        if !deniedLogged {
            log("DENIED cannot read \(watchDir.path): \(error.localizedDescription)")
            log("       Allow Shotcaller under System Settings, Privacy and Security,")
            log("       Files and Folders, then quit and open Shotcaller again.")
            deniedLogged = true
        }
        return
    }

    for name in names where isFreshScreenshot(name) && !skipped.contains(name) {
        let url = watchDir.appendingPathComponent(name)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 1000 else { continue }

        // A screenshot lands on disk before it is finished being written. Only act
        // once its size has held steady across two looks.
        if sizeSeen[name] != size {
            sizeSeen[name] = size
            continue
        }

        guard let text = title(for: url) else {
            sizeSeen.removeValue(forKey: name)
            if timedOut.remove(name) == nil {
                log("SKIP   nothing readable, left alone:  \(name)")
                skipped.insert(name)
            }
            continue
        }

        var newName = text
        if config.keepDate {
            var day: String
            if let m = name.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) {
                day = String(name[m])
            } else {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                day = f.string(from: (attrs[.creationDate] as? Date) ?? Date())
            }
            newName = "\(text) \(day)"
        }

        let ext = (name as NSString).pathExtension
        var target = watchDir.appendingPathComponent("\(newName).\(ext)")
        var n = 2
        while fm.fileExists(atPath: target.path), n <= 50 {
            target = watchDir.appendingPathComponent("\(newName) (\(n)).\(ext)")
            n += 1
        }

        do {
            try fm.moveItem(at: url, to: target)
            log("RENAME \(name)  ->  \(target.lastPathComponent)")
        } catch {
            log("ERROR  could not rename \(name): \(error.localizedDescription)")
            skipped.insert(name)
        }
        sizeSeen.removeValue(forKey: name)
    }
}

// MARK: - run

try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
if !fm.fileExists(atPath: watchDir.path) {
    try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
}

log("START  watching \(watchDir.path)")

// Reading the folder is what makes macOS show its access box on the first run, and
// that call blocks until the box is answered. It runs off the main thread so the
// app is fully awake and logging while it waits, rather than looking frozen.
// One place, one thread, so at most one permission box can ever be pending.
work.async {
    if (try? fm.contentsOfDirectory(atPath: watchDir.path)) == nil {
        log("WAIT   macOS is asking whether Shotcaller may read that folder. Click Allow.")
    }
    watchFolderForChanges()
    pass()
}

// Load Apple's text model now, on its own thread, so the first real screenshot of the
// session is not the one that pays for it.
DispatchQueue.global(qos: .utility).async {
    let warm = Process()
    warm.executableURL = reader
    warm.arguments = ["--warmup"]
    warm.standardOutput = FileHandle.nullDevice
    warm.standardError = FileHandle.nullDevice
    let began = Date()
    try? warm.run()
    warm.waitUntilExit()
    log("READY  text model loaded in \(Int(Date().timeIntervalSince(began)))s")
}

let sweep = DispatchSource.makeTimerSource(queue: work)
sweep.schedule(deadline: .now() + 3, repeating: 30.0)
sweep.setEventHandler {
    autoreleasepool {
        // Pick up a change to where macOS puts screenshots without needing a restart.
        config = loadConfig()
        let current = screenshotFolder(config)
        if current.path != watchDir.path {
            log("MOVED  now watching \(current.path)")
            watchDir = current
            sizeSeen.removeAll()
            skipped.removeAll()
            watchFolderForChanges()
        }
        // Forget the skip list now and then, so a window that was still loading the
        // first time it was read gets another chance rather than being ignored forever.
        if skipped.count > 40 { skipped.removeAll() }
        pass()
    }
}
sweep.resume()

dispatchMain()
