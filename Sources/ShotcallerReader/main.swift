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
// 1. Apple's text recogniser reads every line in the picture.
// 2. If Apple Intelligence is on, Apple's on-device language model looks at the
//    picture itself together with that text, and writes a title that says what the
//    shot is about ("Discord chat about Destiny lore"). The model runs on this Mac.
//    Shotcaller only ever uses the on-device model, never Apple's cloud one.
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

func recognise(_ image: CGImage) -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
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

    // At most ten words, never ending on a word that leaves the title hanging.
    var words = t.split(separator: " ").map(String.init)
    if words.count > 10 {
        words = Array(words.prefix(10))
        let hanging: Set<String> = ["a", "an", "the", "of", "and", "or", "for", "with", "to",
                                    "in", "on", "at", "by", "about", "from", "&", "+", "-"]
        while words.count > 3, let last = words.last, hanging.contains(last.lowercased()) {
            words.removeLast()
        }
        t = words.joined(separator: " ")
    }

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
    if t.count < 4 || t.count > 90 { return true }
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

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct Named {
    @Guide(description: "A 3 to 7 word title saying what the screenshot is about")
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
    // With no text at all, the model invents a subject ("Error message on website
    // page" for a blank square). Better to leave such a file alone.
    guard lines.contains(where: { $0.text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 3 })
    else { return nil }
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40)

    // The context is small, so if the text plus the picture does not fit, try again
    // with less text. The model service also fails now and then for no lasting
    // reason, usually while it is busy loading, so those errors get two more tries.
    var budgets = [1500, 600, 150]
    var retries = 2
    while let budget = budgets.first {
        let text = textForModel(lines, budget: budget)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let reply: LanguageModelSession.Response<Named>
            #if compiler(>=6.4)
            if #available(macOS 27.0, *), let image, model.capabilities.contains(.vision) {
                reply = try await session.respond(generating: Named.self, options: options) {
                    "Text read from the screenshot:"
                    text
                    "The screenshot:"
                    Attachment(image)
                }
            } else {
                guard !text.isEmpty else { return nil }
                reply = try await session.respond(
                    to: "Text read from the screenshot:\n\(text)",
                    generating: Named.self, options: options)
            }
            #else
            guard !text.isEmpty else { return nil }
            reply = try await session.respond(
                to: "Text read from the screenshot:\n\(text)",
                generating: Named.self, options: options)
            #endif
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
    if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
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

// The very first read after a login, or after a long idle, spends up to a minute
// loading Apple's models. Every one after that is quick. With --warmup the reader
// pays that cost on a throwaway image, so a real screenshot never waits.

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
