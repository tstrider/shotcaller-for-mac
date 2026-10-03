// ShotcallerReader
//
// Looks at one screenshot or screen recording and prints a short title for it.
//
// Output, when a title was found:
//   line 1  the title, already safe to use in a filename
//   line 2  how it was found: "model" or "text"
// Prints nothing and exits non-zero when nothing is worth naming a file after,
// which the watcher treats as "leave this file alone".
//
// How the title is found:
//
// 1. Apple's text recogniser reads every line in the picture, in the languages this
//    Mac is set to.
// 2. If Apple Intelligence is on, Apple's on-device language model looks at the
//    picture itself together with that text, says in a sentence what the whole shot
//    shows, and then writes a title from that ("Discord chat about Destiny lore").
//    A photo with no words in it is named from the picture alone. The model runs on
//    this Mac. Shotcaller only ever uses the on-device model, never Apple's cloud one.
// 3. If the model is off, unavailable, or declines, the biggest line of text wins,
//    as it always did.
//
// This runs as its own short-lived process on purpose. Apple's text recogniser
// deadlocks when it is called repeatedly inside a long-running process: it parks
// on a semaphore waiting for the neural engine and never returns. Started fresh for
// one image and then exiting, it is reliable. Keeping it separate also means a
// wedged read can never wedge the watcher.

import Foundation
import Vision
import AppKit
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - reading the text

struct Line {
    let text: String
    let box: CGRect      // normalised, origin at the bottom left, so 1.0 is the top
    var height: Double { Double(box.height) }
    var y: Double { Double(box.midY) }
}

/// The languages to read: the ones this Mac is set to, where the recogniser knows them.
///
/// The recogniser can guess the language instead, but the first time it guesses one it
/// has not met, it spends a minute or two building a model for it, and a screenshot
/// full of names and jargon makes it guess wrongly often. A fixed list means that
/// building happens once, during the warm-up, and never while a real shot waits.
func readingLanguages(_ request: VNRecognizeTextRequest) -> [String] {
    let known = (try? request.supportedRecognitionLanguages()) ?? []
    var chosen: [String] = []
    for wanted in Locale.preferredLanguages {
        // "en-US" is known as it stands, "zh-Hans-CN" as "zh-Hans", "de-AT" as "de-DE".
        let language = wanted.split(separator: "-").first
        let match = known.first { $0 == wanted || wanted.hasPrefix($0 + "-") }
            ?? known.first { $0.split(separator: "-").first == language }
        if let match, !chosen.contains(match) { chosen.append(match) }
    }
    return chosen.isEmpty ? ["en-US"] : Array(chosen.prefix(3))
}

func recognise(_ image: CGImage) -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = false
    request.recognitionLanguages = readingLanguages(request)
    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
        return []
    }
    var lines: [Line] = []
    for observation in request.results ?? [] {
        guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { continue }
        let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append(Line(text: text, box: observation.boundingBox)) }
    }
    return lines
}

/// The text for the model, trimmed to a budget so it always fits alongside the
/// picture in the model's small context. The largest text comes first, because that
/// is where the subject usually is; read top to bottom, a screenshot opens with menu
/// bars, bookmarks and sidebars, and the real subject can fall past the budget.
/// Everything else follows in reading order, so a page of same-size text still reads
/// as it should.
func textForModel(_ lines: [Line], budget: Int) -> String {
    func readingOrder(_ a: Line, _ b: Line) -> Bool {
        abs(a.y - b.y) > 0.01 ? a.y > b.y : a.box.minX < b.box.minX
    }
    let big = Set(lines.indices.sorted { lines[$0].height > lines[$1].height }.prefix(8))
    let headings = big.sorted { readingOrder(lines[$0], lines[$1]) }.map { lines[$0] }
    let rest = lines.indices.filter { !big.contains($0) }.map { lines[$0] }.sorted(by: readingOrder)

    var out = "", used = 0
    func add(_ text: String) -> Bool {
        let piece = String(text.prefix(120))
        if used + piece.count + 1 > budget { return false }
        out += piece + "\n"
        used += piece.count + 1
        return true
    }
    if !headings.isEmpty {
        _ = add("Largest text:")
        for line in headings where !add(line.text) { break }
    }
    if !rest.isEmpty, add("Other text, top to bottom:") {
        for line in rest where !add(line.text) { break }
    }
    return out
}

// MARK: - turning any candidate into a safe, tidy filename

/// Titles that describe nothing. A model sometimes falls back on these.
let generic: Set<String> = [
    "screenshot", "screen shot", "screen recording", "image", "picture", "photo",
    "untitled", "unknown", "none", "n/a", "na", "text", "document", "app", "application",
    "website", "web page", "webpage", "screen", "computer screen", "window", "blank",
    "desktop", "user interface", "interface"
]

/// Makes a title safe and pleasant as a filename, or returns nil if nothing useful
/// is left. Everything the watcher uses as a name passes through here.
func tidy(_ raw: String) -> String? {
    var t = raw
    // Only the first line, and never anything that could not appear in a name.
    t = t.components(separatedBy: .newlines).first ?? ""
    t = String(String.UnicodeScalarView(t.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? " " : $0
    }))
    // Characters that break filenames on macOS, in the Finder, or elsewhere.
    t = t.replacingOccurrences(of: "[/:\\\\|<>*?\"`]", with: " ", options: .regularExpression)
    // Emoji and stray symbols like › or • look bad in the Finder.
    t = String(t.unicodeScalars.filter {
        !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)
          || CharacterSet.symbols.contains($0) && $0 != "&" && $0 != "+" && $0 != "$" && $0 != "%")
    })
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    // A model sometimes opens with the obvious.
    t = t.replacingOccurrences(
        of: "^(a |an |the )?(screenshot|screen shot|screen recording|image|picture)( of| showing| from| with)?[ :,-]+",
        with: "", options: [.regularExpression, .caseInsensitive])
    // File extensions read off the screen ("notes.md", "photo.png") only confuse the
    // name of a file that has its own.
    t = t.replacingOccurrences(
        of: "\\.(png|jpe?g|heic|gif|tiff?|pdf|mov|mp4|md|txt|docx?|xlsx?|pptx?|csv|json|html?|swift|js|ts|py)\\b",
        with: "", options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    // Leading dots would hide the file; quotes and dashes at either end look stray.
    let edges = CharacterSet(charactersIn: " .,;-–—_'‘’“”()[]{}!").union(.whitespaces)
    t = t.trimmingCharacters(in: edges)

    // A whole shouted line reads better in normal case.
    let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    if letters.count >= 8, t == t.uppercased(), t != t.lowercased() {
        t = t.lowercased()
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
    }

    // At most ten words, never ending on a word that leaves the title hanging. A model
    // sometimes stops short too ("Three tweets with").
    var words = t.split(separator: " ").map(String.init)
    let hanging: Set<String> = ["a", "an", "the", "of", "and", "or", "for", "with", "to",
                                "in", "on", "at", "by", "about", "from", "&", "+", "-"]
    words = Array(words.prefix(10))
    while words.count > 2, let last = words.last, hanging.contains(last.lowercased()) {
        words.removeLast()
    }
    t = words.joined(separator: " ")

    // Short enough to read in the Finder, cut on a word boundary. The byte limit keeps
    // room for the date and a counter inside the 255 byte limit on a filename.
    func tooLong(_ s: String) -> Bool { s.count > 60 || s.utf8.count > 180 }
    if tooLong(t) {
        var words = t.split(separator: " ").map(String.init)
        while words.count > 1, tooLong(words.joined(separator: " ")) { words.removeLast() }
        t = words.joined(separator: " ")
        while tooLong(t) { t.removeLast() }
        t = t.trimmingCharacters(in: edges)
    }

    guard t.count >= 3, t.rangeOfCharacter(from: .letters) != nil,
          !generic.contains(t.lowercased()) else { return nil }
    return t
}

// MARK: - the old way: the biggest line of text

// Words that are almost always interface furniture rather than the subject of a shot.
let chrome: Set<String> = [
    "file", "edit", "view", "window", "help", "format", "insert", "tools", "go",
    "bookmarks", "history", "develop", "safari", "chrome", "finder", "firefox",
    "done", "cancel", "ok", "okay", "close", "back", "next", "search", "menu",
    "home", "settings", "more", "open", "save", "share", "print", "today",
    "yesterday", "tomorrow", "submit", "continue", "skip", "accept", "decline",
    "apple", "google", "untitled", "new", "all", "none", "delete", "original",
    "sign", "log", "in", "out", "up", "and", "the", "for", "with"
]

func isJunk(_ t: String) -> Bool {
    if t.count < 4 || t.count > 70 { return true }   // long lines are body text
    if chrome.contains(t.lowercased()) { return true }
    // A row of menu titles reaches the recogniser as one line, so "File Edit View
    // Window Help" arrives as a single candidate.
    let words = t.lowercased().split(separator: " ").map(String.init)
    if words.count >= 2 {
        let furniture = words.filter { chrome.contains($0) }.count
        if Double(furniture) / Double(words.count) >= 0.6 { return true }
    }
    // Prices, clocks, page numbers, battery percentages.
    if t.range(of: "^\\d{1,2}:\\d{2}", options: .regularExpression) != nil { return true }
    let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    return Double(letters) / Double(t.count) < 0.55
}

func biggestLine(_ lines: [Line]) -> String? {
    struct Scored { let line: Line; let score: Double }
    var scored: [Scored] = []
    for line in lines where !isJunk(line.text) {
        // Big text wins, because a heading is a heading because it is large.
        var score = line.height * 100
        // The menu bar strip: small text along the very top. A big heading that
        // happens to sit up there is not penalised.
        if line.y > 0.94, line.height < 0.035 { score *= 0.3 }
        else if line.y > 0.5 { score *= 1.3 }    // headings live in the upper half
        scored.append(Scored(line: line, score: score))
    }
    scored.sort { $0.score > $1.score }
    guard let top = scored.first else { return nil }

    // Glue on the runner up only when it looks like the same heading wrapped onto a
    // second line: close below it, and set in the same size.
    var title = top.line.text
    if title.count < 26, scored.count > 1 {
        let second = scored[1].line
        let sameSize = second.height > top.line.height * 0.75 && second.height < top.line.height * 1.33
        let menuBar = second.y > 0.94 && second.height < 0.035
        if sameSize, !menuBar, abs(top.line.y - second.y) < 0.08 {
            title = second.y > top.line.y ? second.text + " " + title : title + " " + second.text
        }
    }
    return tidy(title)
}

// MARK: - the new way: Apple's on-device model

/// For a model that can only read the text (macOS 26).
let instructions = """
You name screenshot files so that people can find them again months later.
You are shown a screenshot and the text that was read from it, largest text first.
Write one title of 3 to 7 words that says what the screenshot is about.
Name the app or website only when its name or logo is plainly visible in the \
screenshot or the text. Never guess an app. If you are not sure, leave it out.
A name in a bookmark bar, a tab or the dock is not the app.
Then give the specific subject: the topic of the conversation, the headline, the \
product, the error, the setting or the document.
Prefer specific names and words that appear in the screenshot over vague ones.
Ignore menu bars, toolbars, sidebars, ads and other furniture around the main content.
Never begin with the word screenshot. Never include file names or file extensions.
Do not add details that are not shown. No quotation marks, no emoji, no full stop.
Examples of the style wanted:
Chat about weekend hiking plans
Amazon order shipped confirmation
Q3 revenue by region spreadsheet
Xcode build error missing module
"""

/// For a model that can see the picture (macOS 27). It first says what the whole shot
/// shows, and only then writes the title. That keeps a small model from naming the
/// file after whichever line of text stands out: a book title on a spine, the first
/// item of a list, one advert in a feed.
let seeingInstructions = """
You name screenshot files so that people can find them again months later.
You are shown a screenshot and the text read from it.
First say in one sentence what the screenshot shows as a whole. Then write a title \
of 2 to 7 words.
Look at the picture first. The text only helps.
A good title says what the thing is and what it is about.
If the picture is mainly a photo of objects, name the objects plainly, and how many \
if there are a few. Text printed on them, such as book spines, labels or packaging, \
is not the subject.
If it shows a home page or feed full of posts, name the app and the page, not one \
post or ad on it.
If it is a list, name the whole list, not its first item.
If it is a chat or conversation, name the app and what the chat is about.
Ignore ads, menu bars, toolbars, sidebars, bookmarks, the dock and other furniture.
Name an app or website only when its name is written on screen or its logo is \
plainly visible. Never guess one from how the screen looks.
Use specific names from the screenshot where they help. Never invent a category, \
shape, topic or detail that is not shown.
Never begin with the word screenshot. No file names, quotation marks, emoji or full stop.
Examples of good titles:
Chat about weekend hiking plans
Amazon order confirmation for headphones
Blue ceramic mug and saucer
YouTube home page
Weekly chores checklist
Xcode build error missing module
"""

/// Apps and sites a model tends to name from how a screen looks, rather than from
/// anything written on it.
let knownApps: [String] = [
    "notion", "todoist", "canva", "tiktok", "discord", "slack", "reddit", "youtube",
    "twitter", "instagram", "facebook", "threads", "mastodon", "bluesky", "linkedin",
    "whatsapp", "telegram", "signal", "gmail", "outlook", "safari", "chrome", "firefox",
    "figma", "trello", "asana", "evernote", "goodnotes", "habitica", "steam", "spotify",
    "netflix", "amazon", "microsoft", "google", "apple notes", "obsidian", "dropbox",
    "github", "chatgpt", "claude", "codex", "cursor", "vs code", "xcode", "terminal",
    "photoshop", "excel", "word", "powerpoint", "keynote", "pages", "numbers", "zoom",
    "teams", "wikipedia", "twitch", "pinterest", "tumblr", "medium", "substack", "etsy",
    "ebay", "libreoffice", "daydream", "wanderlog", "todo", "to do", "things", "bear", "craft",
    "messenger", "imessage", "snapchat", "tinder", "uber", "airbnb", "doordash"
]

/// A capitalised name in a title that appears nowhere on screen is a guess, such as
/// "Todoist tasks" for a to-do list in some other app. It is dropped when it is a
/// well-known app, or not an ordinary word at all. Names read off the screen stay.
@MainActor
func dropGuessedNames(_ title: String, _ lines: [Line]) -> String {
    let seen = lines.map(\.text).joined(separator: " ").lowercased()
    func onScreen(_ word: String) -> Bool {
        seen.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word.lowercased()),
                   options: .regularExpression) != nil
    }
    var t = title
    for app in knownApps {
        guard let r = t.range(of: "\\b\(app)('s)?\\b", options: [.regularExpression, .caseInsensitive]),
              t[r].first?.isUppercase == true,   // lower case "word" or "pages" is English
              !onScreen(app) else { continue }
        t.removeSubrange(r)
    }
    let checker = NSSpellChecker.shared
    var words = t.split(separator: " ").map(String.init)
    words.removeAll { word in
        var core = word.trimmingCharacters(in: .punctuationCharacters)
        if core.hasSuffix("'s") || core.hasSuffix("’s") { core = String(core.dropLast(2)) }
        guard let first = core.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
              core.count >= 3, core.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              !onScreen(core) else { return false }
        return checker.checkSpelling(of: core, startingAt: 0).location != NSNotFound
    }
    t = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :,-"))
    if t != title, let first = t.first { t = first.uppercased() + t.dropFirst() }
    return t
}

/// A picture with next to nothing in it: one colour, or very nearly.
func looksBlank(_ image: CGImage) -> Bool {
    let side = 32
    var pixels = [UInt8](repeating: 0, count: side * side)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard drawn else { return false }
    let values = pixels.map(Double.init)
    let mean = values.reduce(0, +) / Double(values.count)
    let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    return spread < 6
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct Named {
    @Guide(description: "A 3 to 7 word title saying what the screenshot is about")
    var title: String
}

@available(macOS 26.0, *)
@Generable
struct Described {
    @Guide(description: "One sentence saying what the screenshot shows as a whole: what kind of thing it is, and what it is about")
    var summary: String
    @Guide(description: "A 3 to 7 word title for the file, built from the summary")
    var title: String
}

enum Verdict { case tooLong, declined, transient }

/// Sorts a model error by what to do about it, by its type rather than its wording.
@available(macOS 26.0, *)
func verdict(on error: Error) -> Verdict {
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return .declined
        default: return .transient
        }
    }
    #if compiler(>=6.4)
    if #available(macOS 27.0, *), let e = error as? LanguageModelError {
        switch e {
        case .contextSizeExceeded: return .tooLong
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return .declined
        default: return .transient
        }
    }
    #endif
    return .transient
}

@available(macOS 26.0, *)
func modelTitle(_ image: CGImage?, _ lines: [Line]) async -> String? {
    let model = SystemLanguageModel.default   // on-device, never the cloud model
    guard model.isAvailable else { return nil }
    let hasWords = lines.contains {
        $0.text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 3
    }
    // The picture itself goes to the model only where the model can see (macOS 27).
    var seen: CGImage?
    #if compiler(>=6.4)
    if #available(macOS 27.0, *), model.capabilities.contains(.vision) { seen = image }
    #endif
    // With no words in it, a shot can only be named from the picture. A model that
    // cannot see has nothing to go on, and one that can will still call a blank
    // square something. Such a file is left alone.
    if !hasWords {
        guard let seen, !looksBlank(seen) else { return nil }
    }

    // The context is small, so if the text plus the picture does not fit, try again
    // with less text. The model service also fails now and then for no lasting
    // reason, usually while it is busy loading, so those errors get two more tries.
    var budgets = [1500, 600, 150]
    var retries = 2
    while let budget = budgets.first {
        let text = hasWords ? textForModel(lines, budget: budget) : ""
        do {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *), let seen {
                let session = LanguageModelSession(model: model, instructions: seeingInstructions)
                // Room for the sentence that comes before the title.
                let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
                let reply: LanguageModelSession.Response<Described>
                if text.isEmpty {
                    reply = try await session.respond(generating: Described.self, options: options) {
                        "The screenshot:"
                        Attachment(seen)
                        "No text could be read from it."
                    }
                } else {
                    reply = try await session.respond(generating: Described.self, options: options) {
                        "The screenshot:"
                        Attachment(seen)
                        "Text read from the screenshot, which may include ads, menus and words printed on objects:"
                        text
                    }
                }
                // Nothing to name when the model itself finds the picture empty.
                if !hasWords, reply.content.summary.range(
                    of: "\\b(blank|empty)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    return nil
                }
                return tidy(await dropGuessedNames(reply.content.title, lines))
            }
            #endif
            guard !text.isEmpty else { return nil }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40)
            let reply = try await session.respond(
                to: "Text read from the screenshot:\n\(text)",
                generating: Named.self, options: options)
            return tidy(reply.content.title)
        } catch {
            FileHandle.standardError.write(Data("model: \(error)\n".prefix(400).utf8))
            switch verdict(on: error) {
            case .tooLong:
                budgets.removeFirst()
            case .declined:
                // Guardrails, refusals, unsupported languages: the text will have to do.
                return nil
            case .transient:
                guard retries > 0 else { return nil }
                retries -= 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    return nil
}
#endif

func smartTitle(_ image: CGImage?, _ lines: [Line]) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return await modelTitle(image, lines) }
    #endif
    return nil
}

// MARK: - opening the picture

/// A still from a screen recording, a little way in, when whatever was being shown
/// is usually on screen.
func frame(ofVideo url: URL) async -> CGImage? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 3000, height: 3000)
    let at = CMTime(seconds: min(max(duration.seconds * 0.3, 0), 20), preferredTimescale: 600)
    return try? await generator.image(at: at).image
}

func load(_ path: String) async -> CGImage? {
    let url = URL(fileURLWithPath: path)
    if ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
        return await frame(ofVideo: url)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    // Very large shots are shrunk while they are decoded, never decoded in full first,
    // so a small file that claims enormous dimensions cannot eat the memory. The model
    // sees a few hundred pixels anyway, and the text recogniser is just as accurate
    // and much quicker at this size.
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 3000,
        kCGImageSourceShouldCacheImmediately: true
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

// MARK: - run

// The first read after an install or a macOS update spends a minute or more building
// Apple's text models for this Mac, and the first after a login loads them. Every one
// after that is quick. With --warmup the reader pays that cost on a throwaway image,
// so a real screenshot never waits for it.

let args = Array(CommandLine.arguments.dropFirst())
let useModel = !args.contains("--no-model")
let files = args.filter { !$0.hasPrefix("--") }

if args.contains("--warmup") {
    let size = NSSize(width: 400, height: 120)
    let canvas = NSImage(size: size)
    canvas.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    "warming up".draw(at: NSPoint(x: 20, y: 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black
    ])
    canvas.unlockFocus()
    if let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let lines = recognise(cg)
        if useModel { _ = await smartTitle(cg, lines) }
    }
    exit(0)
}

guard let path = files.first else {
    FileHandle.standardError.write(Data("usage: ShotcallerReader [--no-model] <image or video> | --warmup\n".utf8))
    exit(2)
}
guard let image = await load(path) else { exit(3) }
let lines = recognise(image)

if useModel, let title = await smartTitle(image, lines) {
    print(title)
    print("model")
    exit(0)
}
if let title = biggestLine(lines) {
    print(title)
    print("text")
    exit(0)
}
exit(5)
