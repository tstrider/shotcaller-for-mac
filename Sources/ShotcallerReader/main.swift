// ShotcallerReader
//
// Reads the text in one image and prints the line that looks most like its title.
// Prints nothing and exits non-zero when nothing in the image is worth naming a
// file after, which the watcher treats as "leave this file alone".
//
// This runs as its own short-lived process on purpose. Apple's text recogniser
// deadlocks when it is called repeatedly inside a long-running process: it parks
// on a semaphore waiting for the neural engine and never returns, on the main run
// loop and on a background queue alike. Started fresh for one image and then
// exiting, it is reliable. Keeping it separate also means a wedged read can never
// wedge the watcher.

import Foundation
import Vision
import AppKit

// Words that are almost always interface furniture rather than the subject of a shot.
let chrome: Set<String> = [
    "file", "edit", "view", "window", "help", "format", "insert", "tools", "go",
    "bookmarks", "history", "develop", "safari", "chrome", "finder", "firefox",
    "done", "cancel", "ok", "okay", "close", "back", "next", "search", "menu",
    "home", "settings", "more", "open", "save", "share", "print", "today",
    "yesterday", "tomorrow", "submit", "continue", "skip", "accept", "decline",
    "apple", "google", "untitled", "new", "all", "none", "edit", "delete",
    "sign", "log", "in", "out", "up", "and", "the", "for", "with"
]

func isJunk(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count < 4 || t.count > 70 { return true }
    if chrome.contains(t.lowercased()) { return true }

    // A row of menu titles reaches the recogniser as one line, so "File Edit View
    // Window Help" arrives as a single candidate. Reject anything mostly built out
    // of interface words.
    let words = t.lowercased().split(separator: " ").map(String.init)
    if words.count >= 2 {
        let furniture = words.filter { chrome.contains($0) }.count
        if Double(furniture) / Double(words.count) >= 0.6 { return true }
    }

    // No letters at all, so prices, clocks, page numbers, battery percentages.
    if t.rangeOfCharacter(from: .letters) == nil { return true }
    // A clock.
    if t.range(of: "^\\d{1,2}:\\d{2}", options: .regularExpression) != nil { return true }
    // Mostly digits and punctuation.
    let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    if Double(letters) / Double(t.count) < 0.55 { return true }
    return false
}

func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // Characters that break filenames, or that simply look bad in Finder.
    t = t.replacingOccurrences(of: "[/:\\\\|<>*?\"]", with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,-–—_"))
    return t
}

struct Line {
    let text: String
    let score: Double
    let y: Double
    let height: Double
}

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: ShotcallerReader <image>|--warmup\n".utf8))
    exit(2)
}

// The very first text recognition after a login, or after a long idle, spends up to
// a minute loading Apple's model. Every one after that is quick, because the loaded
// model is shared across the whole system. Shotcaller pays that cost once at login
// on a throwaway image, so the first real screenshot is not the one that waits.
if args[1] == "--warmup" {
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
        let warm = VNRecognizeTextRequest()
        warm.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([warm])
    }
    exit(0)
}

guard let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    exit(3)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

do {
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
    exit(4)
}

guard let results = request.results, !results.isEmpty else { exit(5) }

var lines: [Line] = []
for observation in results {
    guard let best = observation.topCandidates(1).first else { continue }
    if best.confidence < 0.35 { continue }
    let text = clean(best.string)
    if isJunk(text) { continue }

    let box = observation.boundingBox    // normalised, origin at the bottom left
    let height = Double(box.height)      // stands in for font size
    let y = Double(box.midY)             // 1.0 is the top of the image

    // Big text wins, because a heading is a heading because it is large. Position
    // only nudges. Confidence filters above rather than multiplying here, since a
    // large display font often scores lower confidence than clean body text and
    // would lose for no good reason.
    var score = height * 100.0
    if y > 0.94 { score *= 0.3 }         // the menu bar strip, almost never the subject
    else if y > 0.5 { score *= 1.3 }     // page and window headings live in the upper half

    lines.append(Line(text: text, score: score, y: y, height: height))
}

guard !lines.isEmpty else { exit(6) }
lines.sort { $0.score > $1.score }

// Glue the runner up on only when it looks like the same heading wrapped onto a
// second line: close vertically, and set in the same size. Without the size test a
// small label elsewhere on the page gets welded onto the title.
var title = lines[0].text
if title.count < 26, lines.count > 1 {
    let top = lines[0], second = lines[1]
    let sameSize = second.height > top.height * 0.75 && second.height < top.height * 1.33
    if sameSize, abs(second.y - top.y) < 0.08 {
        let joined = clean(title + " " + second.text)
        if joined.count <= 70 { title = joined }
    }
}

if title.count > 60 {
    let cut = title.prefix(60)
    if let space = cut.lastIndex(of: " ") {
        title = clean(String(cut[cut.startIndex..<space]))
    } else {
        title = clean(String(cut))
    }
}

guard title.count >= 4 else { exit(7) }
print(title)
