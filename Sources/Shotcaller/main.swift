// Shotcaller
//
// Watches your screenshot folder and renames each new screenshot after what it
// shows, so "Screenshot 2026-09-21 at 3.45.12 PM.png" becomes
// "Discord chat about Destiny lore 2026-09-21.png". Screen recordings get the
// same treatment, named after a frame from early in the recording.
//
// Two things here exist for reasons that are not obvious:
//
// 1. This ships as an app bundle rather than a plain background script. macOS
//    refuses an unbundled script any access to Desktop, Documents and Downloads,
//    and denies it silently, with no prompt and no error. A bundled app with its
//    own identifier is allowed to ask, so the usual access box appears instead.
//
// 2. The looking happens in a separate helper process with a time limit. Apple's
//    models take up to a minute to load the first time after a login and are fast
//    after that, so Shotcaller loads them on a throwaway image at startup. Keeping
//    the reader separate means a slow or stuck read can never stop the watcher, and
//    the reader never needs folder permission of its own.
//
// Shotcaller never deletes anything. A file it cannot find a sensible title for
// keeps the name macOS gave it.

import Foundation

// MARK: - settings

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Shotcaller")
let logFile = supportDir.appendingPathComponent("shotcaller.log")
let configFile = supportDir.appendingPathComponent("config.json")
// Next to this executable, which is where install.sh puts it.
let reader = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("ShotcallerReader")
// Private scratch space for the copies the reader looks at, one per running copy of
// Shotcaller, so two copies can never clear out each other's files.
let scratchRoot = fm.temporaryDirectory
let scratchDir = scratchRoot.appendingPathComponent("com.strider.shotcaller-\(getpid())")

let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]
let videoTypes: Set<String> = ["mov", "mp4"]

struct Config: Codable, Equatable {
    /// Folder to watch. Empty means "ask macOS where screenshots go".
    var watchFolder = ""
    /// Keep the date in the new filename, so the folder still sorts by when.
    var keepDate = true
    /// Let Apple's on-device model look at the shot and write the title. When off,
    /// or when Apple Intelligence is not available, the biggest line of text is used.
    var useAppleIntelligence = true
    /// Rename screen recordings too, after a frame from early in the recording.
    var renameRecordings = true
    /// Filename prefixes macOS uses for a fresh screenshot, per language. Only files
    /// starting with one of these are ever touched, which is also what stops a file
    /// Shotcaller has already renamed from being picked up a second time.
    var prefixes: [String] = [
        "screenshot", "screen shot",          // English
        "bildschirmfoto",                     // German
        "captura de pantalla",                // Spanish
        "capture d'écran", "capture d’écran", // French
        "istantanea schermo",                 // Italian
        "schermafbeelding",                   // Dutch
        "skärmavbild",                        // Swedish
        "zrzut ekranu",                       // Polish
        "captura de ecrã", "captura de tela", // Portuguese
        "снимок экрана",                      // Russian
        "스크린샷",                              // Korean
        "スクリーンショット",                       // Japanese
        "截屏", "螢幕截圖", "截圖"                 // Chinese
    ]
    /// The same for screen recordings.
    var recordingPrefixes: [String] = [
        "screen recording", "bildschirmaufnahme", "grabación de pantalla",
        "enregistrement de l’écran", "enregistrement de l'écran", "registrazione schermo",
        "schermopname", "skärminspelning", "nagranie ekranu", "gravação de tela",
        "gravação do ecrã", "запись экрана", "화면 기록", "画面収録", "录屏", "螢幕錄影"
    ]

    init() {}

    // Every key is optional, so a config.json from an older version, or one with a
    // key deleted by hand, still loads and keeps the settings that are there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        watchFolder = try c.decodeIfPresent(String.self, forKey: .watchFolder) ?? d.watchFolder
        keepDate = try c.decodeIfPresent(Bool.self, forKey: .keepDate) ?? d.keepDate
        useAppleIntelligence = try c.decodeIfPresent(Bool.self, forKey: .useAppleIntelligence) ?? d.useAppleIntelligence
        renameRecordings = try c.decodeIfPresent(Bool.self, forKey: .renameRecordings) ?? d.renameRecordings
        prefixes = Config.usable(try c.decodeIfPresent([String].self, forKey: .prefixes) ?? d.prefixes)
        recordingPrefixes = Config.usable(
            try c.decodeIfPresent([String].self, forKey: .recordingPrefixes) ?? d.recordingPrefixes)
    }

    /// A blank or one letter prefix would match nearly every file in the folder.
    static func usable(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.count >= 2 }
    }
}

var configStamp: Date?
var configBroken = false

/// Reads config.json when it has changed since last time. A file with a mistake in
/// it is never overwritten: the last good settings stay in use and the log says why.
func loadConfig(_ current: Config) -> Config {
    guard let attrs = try? fm.attributesOfItem(atPath: configFile.path),
          let data = try? Data(contentsOf: configFile) else {
        save(Config())
        return Config()
    }
    let stamp = attrs[.modificationDate] as? Date
    if stamp == configStamp { return current }
    configStamp = stamp
    do {
        let parsed = try JSONDecoder().decode(Config.self, from: data)
        if configBroken { log("CONFIG config.json reads fine again"); configBroken = false }
        // Add any settings this version knows about that the file does not show yet.
        if let keys = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           keys.count < 6 {
            save(parsed)
        }
        return parsed
    } catch {
        if !configBroken {
            log("CONFIG config.json has a mistake in it, so the last good settings stay in use")
            configBroken = true
        }
        return current
    }
}

func save(_ config: Config) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(config) else { return }
    try? data.write(to: configFile, options: .atomic)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    configStamp = (try? fm.attributesOfItem(atPath: configFile.path))?[.modificationDate] as? Date
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

// Fixed to the Gregorian calendar, so a Mac set to another calendar still gets
// dates like 2026-09-21 rather than 2569-09-21.
func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = format
    return f
}
let stamp = formatter("yyyy-MM-dd HH:mm:ss")
let dayFormat = formatter("yyyy-MM-dd")
var linesSinceTrim = 0

// Called from more than one thread, so writes take turns.
let logLock = NSLock()

func log(_ message: String) {
    logLock.lock(); defer { logLock.unlock() }
    // A filename can hold a line break; it must not be able to forge a log line.
    let flat = String(String.UnicodeScalarView(message.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? " " : $0
    }))
    let data = Data("\(stamp.string(from: Date()))  \(flat)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: logFile) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        // The log lists what your screenshots were about, so only you may read it.
        fm.createFile(atPath: logFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    // Keep the log from growing without limit. Checked now and then, not every line.
    linesSinceTrim += 1
    guard linesSinceTrim >= 50 else { return }
    linesSinceTrim = 0
    if let size = try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int, size > 512_000,
       let text = try? String(contentsOf: logFile, encoding: .utf8) {
        let kept = text.split(separator: "\n").suffix(2000).joined(separator: "\n")
        try? (kept + "\n").write(to: logFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - asking the reader what the picture shows

enum Reading {
    case named(String, how: String)
    case nothing      // the reader found nothing worth naming the file after
    case timedOut
    case tooBig       // too large to copy from another disk
}

/// Runs the reader with a time limit, and returns what it printed.
func runReader(_ arguments: [String], limit: TimeInterval) -> (status: Int32, output: String)? {
    let task = Process()
    task.executableURL = reader
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch {
        log("ERROR  could not start the reader: \(error.localizedDescription)")
        return (-1, "")
    }

    // Read while waiting, so a chatty reader can never fill the pipe and stall.
    var output = Data()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        finished.signal()
    }
    if finished.wait(timeout: .now() + limit) == .timedOut {
        task.terminate()
        if finished.wait(timeout: .now() + 3) == .timedOut { kill(task.processIdentifier, SIGKILL) }
        return nil
    }
    return (task.terminationStatus, String(decoding: output, as: UTF8.self))
}

func read(_ url: URL) -> Reading {
    // Look at a copy, so the reader never touches a protected folder and needs no
    // permission of its own. On APFS the copy is a clone and costs nothing.
    let scratch = scratchDir.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
    // Across disks there is no clone, and the copy is real. A huge recording on
    // another drive is not worth copying just to look at one frame of it.
    let volumes = [url, scratchDir].map {
        (try? $0.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
    if volumes[0] != volumes[1],
       let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 300_000_000 {
        return .tooBig
    }
    do { try fm.copyItem(at: url, to: scratch) } catch { return .nothing }
    defer { try? fm.removeItem(at: scratch) }

    let started = Date()
    // Generous, because a cold model load genuinely can take a minute or more.
    let args = config.useAppleIntelligence ? [scratch.path] : ["--no-model", scratch.path]
    guard let (status, output) = runReader(args, limit: 150) else { return .timedOut }
    let seconds = Date().timeIntervalSince(started)
    if seconds > 20 { log("SLOW   that took \(Int(seconds))s, Apple's models were loading or busy") }

    let lines = output.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard status == 0, let title = lines.first.map(safeName), title.count >= 3 else { return .nothing }
    return .named(title, how: lines.count > 1 ? lines[1] : "text")
}

/// A second line of defence behind the reader's own tidying: whatever comes back is
/// made safe before it can become part of a path.
func safeName(_ s: String) -> String {
    var t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    t = t.replacingOccurrences(of: "[/:\\\\]", with: " ", options: .regularExpression)
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespaces))
    while t.utf8.count > 180 { t.removeLast() }
    return t
}

// MARK: - the rename pass

var config = Config()
var watchDir = home
var sizeSeen: [String: Int] = [:]   // sizes from the last look, so half written files wait
var tries: [String: Int] = [:]      // how often a file has been read without success
var notBefore: [String: Date] = [:] // when a file that failed is worth another look
var deniedLogged = false
let maxTries = 3

let work = DispatchQueue(label: "com.strider.shotcaller.work", qos: .utility)

// The folder tells us when it changes, so there is no busy polling. A slow sweep
// runs underneath it as a backstop, and also catches the screenshot folder being
// moved in System Settings while Shotcaller is running.
var vnode: DispatchSourceFileSystemObject?

// Always called on `work`. Opening the folder blocks for as long as the macOS
// permission box is unanswered, so it must never run on the main thread.
func watchFolderForChanges() {
    vnode?.cancel()
    vnode = nil
    let fd = open(watchDir.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: work)
    source.setEventHandler {
        // The folder itself was moved or deleted: start again on whatever is there now.
        if !source.data.intersection([.rename, .delete]).isEmpty {
            work.asyncAfter(deadline: .now() + 2) { watchFolderForChanges() }
        }
        // Give the writer a moment to finish before looking.
        schedulePass(after: 0.7)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    vnode = source
}

// A burst of folder events becomes one pass, not one pass per event.
var passScheduled = false
func schedulePass(after delay: TimeInterval) {
    guard !passScheduled else { return }
    passScheduled = true
    work.asyncAfter(deadline: .now() + delay) {
        passScheduled = false
        autoreleasepool { pass() }
    }
}

func isFresh(_ name: String) -> Bool {
    let lower = name.lowercased()
    // macOS writes a hidden file first and then renames it into place.
    guard !lower.hasPrefix(".") else { return false }
    let ext = (lower as NSString).pathExtension
    if imageTypes.contains(ext) { return config.prefixes.contains { lower.hasPrefix($0) } }
    if videoTypes.contains(ext), config.renameRecordings {
        return config.recordingPrefixes.contains { lower.hasPrefix($0) }
    }
    return false
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
        // The folder was deleted or moved away in the Finder: make it again, the way
        // macOS would, rather than blaming permissions.
        if !fm.fileExists(atPath: watchDir.path) {
            log("MISSING \(watchDir.path) is gone, so it has been made again")
            try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
            watchFolderForChanges()
            return
        }
        if !deniedLogged {
            log("DENIED cannot read \(watchDir.path): \(error.localizedDescription)")
            log("       Allow Shotcaller under System Settings, Privacy and Security,")
            log("       Files and Folders, then quit and open Shotcaller again.")
            deniedLogged = true
        }
        return
    }

    // Forget files that are gone, so this state never grows without limit.
    let present = Set(names)
    sizeSeen = sizeSeen.filter { present.contains($0.key) }
    tries = tries.filter { present.contains($0.key) }
    notBefore = notBefore.filter { present.contains($0.key) }

    var lookAgainSoon = false
    let now = Date()

    for name in names where isFresh(name) {
        if (tries[name] ?? 0) >= maxTries { continue }
        if let wait = notBefore[name], wait > now { continue }

        let url = watchDir.appendingPathComponent(name)
        // Only real files. A link named like a screenshot could point anywhere.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size > 1000 else { continue }

        // A file lands on disk before it is finished being written. Only act once its
        // size has held steady across two looks and it has sat untouched for a moment,
        // longer for a recording. macOS itself writes screenshots out of sight and
        // moves them in whole, but a copied or synced file arrives a piece at a time.
        let isVideo = videoTypes.contains((name as NSString).pathExtension.lowercased())
        let modified = attrs[.modificationDate] as? Date ?? now
        if sizeSeen[name] != size || now.timeIntervalSince(modified) < (isVideo ? 5 : 2) {
            sizeSeen[name] = size
            lookAgainSoon = true
            continue
        }

        switch read(url) {
        case .timedOut:
            tries[name, default: 0] += 1
            notBefore[name] = Date().addingTimeInterval(60)
            let last = tries[name]! >= maxTries
            log("ERROR  ran out of time reading \(name), " + (last ? "giving up on it" : "will try again in a minute"))
            continue
        case .nothing:
            tries[name, default: 0] += 1
            notBefore[name] = Date().addingTimeInterval(600)
            if tries[name]! >= maxTries {
                log("SKIP   nothing worth naming it after, left alone:  \(name)")
            } else if tries[name] == 1 {
                log("SKIP   nothing worth naming it after yet, will look again later:  \(name)")
            }
            continue
        case .tooBig:
            tries[name] = maxTries
            log("SKIP   too large to copy from another disk, left alone:  \(name)")
            continue
        case .named(let title, let how):
            rename(url, name: name, title: title, how: how, created: attrs[.creationDate] as? Date)
        }
        sizeSeen.removeValue(forKey: name)
    }

    if lookAgainSoon { schedulePass(after: 1.5) }
}

func rename(_ url: URL, name: String, title: String, how: String, created: Date?) {
    var newName = title
    if config.keepDate {
        let day: String
        if let m = name.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) {
            day = String(name[m])
        } else {
            day = dayFormat.string(from: created ?? Date())
        }
        newName = "\(title) \(day)"
    }

    let ext = (name as NSString).pathExtension
    // A title such as "Screenshots app settings" would give a name that still looks
    // like a fresh screenshot, and Shotcaller would rename it again, forever.
    if isFresh("\(newName).\(ext)") {
        log("SKIP   its title would look like a new screenshot, left alone:  \(name)")
        tries[name] = maxTries
        return
    }
    var target = watchDir.appendingPathComponent("\(newName).\(ext)")
    var n = 2
    while fm.fileExists(atPath: target.path), n <= 99 {
        target = watchDir.appendingPathComponent("\(newName) (\(n)).\(ext)")
        n += 1
    }

    do {
        // Never replaces anything: this fails rather than overwrite an existing file.
        try fm.moveItem(at: url, to: target)
        let note = how == "model" ? "" : "  (from the text)"
        log("RENAME \(name)  ->  \(target.lastPathComponent)\(note)")
    } catch {
        log("ERROR  could not rename \(name): \(error.localizedDescription)")
        tries[name] = maxTries
    }
}

// MARK: - run

try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
// Clear out copies left behind by a Shotcaller that was stopped halfway through a
// read. Only folders whose process is gone; another running copy keeps its own.
for leftover in (try? fm.contentsOfDirectory(atPath: scratchRoot.path)) ?? []
where leftover.hasPrefix("com.strider.shotcaller") || leftover.hasPrefix("shotcaller-") {
    // Version 1 left single files named shotcaller-<id> behind.
    let pid = Int32(leftover.split(separator: "-").last ?? "") ?? 0
    if pid <= 0 || kill(pid, 0) != 0 {
        try? fm.removeItem(at: scratchRoot.appendingPathComponent(leftover))
    }
}
try? fm.createDirectory(at: scratchDir, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
// Older versions left these readable by anyone on the Mac.
for file in [logFile, configFile] where fm.fileExists(atPath: file.path) {
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

config = loadConfig(config)
watchDir = screenshotFolder(config)
log("START  watching \(watchDir.path)")

// Reading the folder is what makes macOS show its access box on the first run, and
// that call blocks until the box is answered. It runs off the main thread so the
// app is fully awake and logging while it waits, rather than looking frozen.
// One place, one thread, so at most one permission box can ever be pending.
work.async {
    if !fm.fileExists(atPath: watchDir.path) {
        try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
    }
    if (try? fm.contentsOfDirectory(atPath: watchDir.path)) == nil {
        log("WAIT   macOS is asking whether Shotcaller may read that folder. Click Allow.")
    }
    watchFolderForChanges()
    pass()
}

// Load Apple's models now, on their own thread, so the first real screenshot of the
// session is not the one that pays for it.
let warmArgs = config.useAppleIntelligence ? ["--warmup"] : ["--warmup", "--no-model"]
DispatchQueue.global(qos: .utility).async {
    let began = Date()
    if runReader(warmArgs, limit: 300) == nil {
        log("SLOW   Apple's models are taking a long time to load")
    } else {
        log("READY  models loaded in \(Int(Date().timeIntervalSince(began)))s")
    }
}

let sweep = DispatchSource.makeTimerSource(queue: work)
sweep.schedule(deadline: .now() + 30, repeating: 30.0, leeway: .seconds(5))
sweep.setEventHandler {
    autoreleasepool {
        // Pick up edits to the settings, and a change to where macOS puts
        // screenshots, without needing a restart.
        config = loadConfig(config)
        let current = screenshotFolder(config)
        if current.path != watchDir.path {
            log("MOVED  now watching \(current.path)")
            watchDir = current
            sizeSeen.removeAll()
            tries.removeAll()
            notBefore.removeAll()
            watchFolderForChanges()
        } else if vnode == nil {
            watchFolderForChanges()
        }
        pass()
    }
}
sweep.resume()

dispatchMain()
