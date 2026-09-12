import Foundation
import AppKit
import CheapshotCore

// MARK: - CLI

func usage() {
    print("""
    cheapshot \(cheapshotVersion) - on-device screenshot OCR for AI agents

    USAGE
      cheapshot <file.png> [more.png ...]
      cheapshot --newest <dir> [n]
      cheapshot --cleanshot [n]
      cheapshot --video <file.mp4>

    OPTIONS
      --raw             do not redact (redaction is ON by default)
      --json            emit JSON
      --stats           print token savings to stderr
      --min-conf <f>    confidence floor, default 0.3
      --scene <f>       video scene-change threshold, default 0.25
      --max-frames <n>  video frame cap, default 200
      --dedupe <f>      drop a screen this similar to the last, default 0.90
      --ledger          print cumulative savings across every run
      --no-ledger       do not record this run
      --version
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { usage(); exit(0) }
if args.contains("--version") { print(cheapshotVersion); exit(0) }
if args.contains("--ledger") { ledgerTotal(); exit(0) }

var doRedact = true, asJSON = false, showStats = false
var minConf: Float = 0.3
var files: [String] = []

func popValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if args.contains("--raw")   { doRedact = false; args.removeAll { $0 == "--raw" } }
if args.contains("--json")  { asJSON = true;    args.removeAll { $0 == "--json" } }
if args.contains("--stats") { showStats = true; args.removeAll { $0 == "--stats" } }
var noLedger = false
if args.contains("--no-ledger") { noLedger = true; args.removeAll { $0 == "--no-ledger" } }
if let c = popValue("--min-conf"), let f = Float(c) { minConf = f }

var videoPath: String? = nil
var sceneThreshold = 0.25
var maxFrames = 200
var dedupe = 0.90
if let v = popValue("--video") { videoPath = v }
if let s = popValue("--scene"), let d = Double(s) { sceneThreshold = d }
if let m = popValue("--max-frames"), let i = Int(m) { maxFrames = i }
if let d = popValue("--dedupe"), let x = Double(d) { dedupe = x }

if let vp = videoPath {
    guard FileManager.default.fileExists(atPath: vp) else {
        FileHandle.standardError.write("cheapshot: no such video \(vp)\n".data(using: .utf8)!); exit(2)
    }
    guard let (tmp, frames) = sceneFrames(video: vp, threshold: sceneThreshold, maxFrames: maxFrames),
          !frames.isEmpty else {
        FileHandle.standardError.write("cheapshot: no frames extracted\n".data(using: .utf8)!); exit(1)
    }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var kept: [(Double, String)] = []
    var lastText = ""
    var frameImageTokens = 0
    for (t, f) in frames {
        frameImageTokens += imageTokens(path: f)
        guard let raw = ocr(path: f, minConfidence: minConf) else { continue }
        let text = doRedact ? Redactor().redact(raw).text : raw
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if similarity(trimmed, lastText) >= dedupe { continue }
        kept.append((t, trimmed))
        lastText = trimmed
    }

    var body = ""
    for (t, text) in kept { body += "[\(stamp(t))]\n\(text)\n\n" }
    print(body.trimmingCharacters(in: .whitespacesAndNewlines))

    let vtt = textTokens(body)
    if !noLedger { ledgerAppend(mode: "video", inputs: frames.count, imageTokens: frameImageTokens, textTokens: vtt, redactions: 0) }
    if showStats {
        let tt = vtt
        let msg = "cheapshot: \(frames.count) scene frames, \(kept.count) distinct screens  "
                + "\(frameImageTokens) image tokens -> \(tt) text tokens  "
                + "(saved \(max(0, frameImageTokens - tt)), "
                + "\(frameImageTokens > 0 ? Int(Double(max(0, frameImageTokens - tt)) / Double(frameImageTokens) * 100) : 0)%)\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }
    exit(0)
}

func newest(in dir: String, count: Int) -> [String] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    let pngs = items.filter { $0.lowercased().hasSuffix(".png") || $0.lowercased().hasSuffix(".jpg") }
    let withDates: [(String, Date)] = pngs.compactMap {
        let p = (dir as NSString).appendingPathComponent($0)
        let d = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil
        return d.map { (p, $0) }
    }
    return withDates.sorted { $0.1 > $1.1 }.prefix(count).map { $0.0 }
}

func cleanshotDir() -> String {
    let d = UserDefaults(suiteName: "pl.maketheweb.cleanshotx")?.string(forKey: "exportPath")
    return d ?? (NSHomeDirectory() + "/Dropbox/_Screenshots")
}

if let i = args.firstIndex(of: "--newest") {
    let dir = i + 1 < args.count ? args[i + 1] : "."
    let n = (i + 2 < args.count ? Int(args[i + 2]) : 1) ?? 1
    files = newest(in: dir, count: n)
} else if let i = args.firstIndex(of: "--cleanshot") {
    let n = (i + 1 < args.count ? Int(args[i + 1]) : 1) ?? 1
    files = newest(in: cleanshotDir(), count: n)
} else {
    files = args.filter { !$0.hasPrefix("--") }
}

if files.isEmpty {
    FileHandle.standardError.write("cheapshot: no input images\n".data(using: .utf8)!)
    exit(2)
}

var totalImageTokens = 0, totalTextTokens = 0, totalRedactions = 0
var jsonOut: [[String: Any]] = []
var failed = 0

for f in files {
    guard let raw = ocr(path: f, minConfidence: minConf) else {
        FileHandle.standardError.write("cheapshot: cannot read \(f)\n".data(using: .utf8)!)
        failed += 1
        continue
    }
    let (text, report) = doRedact ? Redactor().redact(raw) : (raw, RedactionReport())
    let it = imageTokens(path: f), tt = textTokens(text)
    totalImageTokens += it; totalTextTokens += tt
    totalRedactions += report.total

    if asJSON {
        jsonOut.append(["file": f, "text": text, "redactions": report.counts,
                        "image_tokens": it, "text_tokens": tt])
    } else {
        if files.count > 1 { print("== \((f as NSString).lastPathComponent)") }
        print(text)
    }
}

if asJSON {
    let payload: [String: Any] = ["version": cheapshotVersion, "results": jsonOut,
                                  "image_tokens": totalImageTokens, "text_tokens": totalTextTokens]
    if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
}

if !noLedger {
    ledgerAppend(mode: "image", inputs: files.count - failed, imageTokens: totalImageTokens,
                 textTokens: totalTextTokens, redactions: totalRedactions)
}

if showStats {
    let saved = max(0, totalImageTokens - totalTextTokens)
    let pct = totalImageTokens > 0 ? Int(Double(saved) / Double(totalImageTokens) * 100) : 0
    let msg = "cheapshot: \(files.count - failed) image(s)  \(totalImageTokens) image tokens -> \(totalTextTokens) text tokens  (saved \(saved), \(pct)%)\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
}

exit(failed > 0 && failed == files.count ? 1 : 0)
