// cheapshot - on-device screenshot OCR for AI agents.
// Turns screenshots into redacted text so agents read words, not pixels.
// Apple Vision. No network. No API cost.

import Foundation
import AppKit
import Vision

let VERSION = "0.4.1"

// MARK: - PII redaction

struct Rule {
    let name: String
    let pattern: String
    let opts: NSRegularExpression.Options
    init(_ name: String, _ pattern: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) {
        self.name = name; self.pattern = pattern; self.opts = opts
    }
}

// Ordered: most specific first, so a key is not eaten by a looser rule.
let RULES: [Rule] = [
    Rule("AWS_KEY",     #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#, []),
    Rule("GITHUB_PAT",  #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, []),
    Rule("OPENAI_KEY",  #"\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_\-]{20,}\b"#, []),
    Rule("SLACK_TOKEN", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#, []),
    Rule("JWT",         #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, []),
    Rule("PRIVATE_KEY", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, []),
    Rule("BEARER",      #"\bBearer\s+[A-Za-z0-9._\-]{16,}"#),
    Rule("EMAIL",       #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
    Rule("SSN",         #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#, []),
    Rule("ROUTING",     #"\b\d{4}[ \-]?\d{4}[ \-]?\d\b"#, []),
    Rule("CARD",        #"\b\d(?:[ \-]?\d){12,18}\b"#, []),
    Rule("BANK_ACCT",   #"(?<![\w\-/])\d{8,}(?![\w\-/])"#, []),
    Rule("PHONE",       #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, []),
    Rule("TOKEN",       #"(?<![A-Za-z0-9_\-+/=.])(?=[A-Za-z0-9_\-+/=.]*[a-z])(?=[A-Za-z0-9_\-+/=.]*[A-Z])[A-Za-z0-9_\-+/=.]{20,}"#, []),
    Rule("IPV4",        #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#, []),
]

// Luhn check so we only redact things that are actually card numbers.
func passesLuhn(_ s: String) -> Bool {
    let digits = s.compactMap { $0.wholeNumberValue }
    guard digits.count >= 13, digits.count <= 19 else { return false }
    var sum = 0
    for (i, d) in digits.reversed().enumerated() {
        if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
    }
    return sum % 10 == 0
}


// ABA routing numbers carry their own checksum. Validating it keeps this rule
// from eating every 9-digit number in a document.
func passesABA(_ s: String) -> Bool {
    let d = s.compactMap { $0.wholeNumberValue }
    guard d.count == 9 else { return false }
    let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
    return sum % 10 == 0
}

// Shannon entropy, bits per character.
func entropy(_ s: String) -> Double {
    guard !s.isEmpty else { return 0 }
    var freq: [Character: Int] = [:]
    for c in s { freq[c, default: 0] += 1 }
    let n = Double(s.count)
    return freq.values.reduce(0.0) { acc, c in
        let p = Double(c) / n
        return acc - p * log2(p)
    }
}

// TOKEN is the catch-all for secrets with no recognizable prefix. Every
// prefixed secret (AKIA, ghp_, sk-, xoxb-, eyJ) is already caught by a specific
// rule earlier in RULES, so this one can afford a high bar — and it needs one.
// Its character class contains "/" and ".", so without a gate it swallows every
// absolute path and every screenshot filename it sees. Measured on real input:
// paths and CleanShot filenames top out at 4.14 bits/char, prefix-less secrets
// start at 4.66. 4.4 sits in the gap.
func looksLikeSecret(_ s: String) -> Bool {
    if s.contains("://") { return false }   // URL
    if s.hasPrefix("/")  { return false }   // absolute path
    return entropy(s) >= 4.4
}

struct RedactionReport { var counts: [String: Int] = [:] }

func redact(_ input: String) -> (String, RedactionReport) {
    var text = input
    var report = RedactionReport()
    for rule in RULES {
        guard let re = try? NSRegularExpression(pattern: rule.pattern, options: rule.opts) else { continue }
        var result = ""
        var last = text.startIndex
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            let hit = String(text[r])
            // Card rule only fires on a real Luhn-valid number.
            if rule.name == "CARD" && !passesLuhn(hit) { continue }
            if rule.name == "ROUTING" && !passesABA(hit) { continue }
            // Without this, every /Users/... path in the shot becomes [TOKEN].
            if rule.name == "TOKEN" && !looksLikeSecret(hit) { continue }
            result += text[last..<r.lowerBound] + "[\(rule.name)]"
            report.counts[rule.name, default: 0] += 1
            last = r.upperBound
        }
        if last != text.startIndex || !matches.isEmpty {
            result += text[last...]
            text = result
        }
    }
    return (text, report)
}

// MARK: - OCR

func ocr(path: String, minConfidence: Float) -> String? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([request]) } catch { return nil }

    guard let obs = request.results else { return "" }

    // Sort top-to-bottom, then left-to-right. Vision's origin is bottom-left.
    let sorted = obs.sorted { a, b in
        let ay = a.boundingBox.origin.y, by = b.boundingBox.origin.y
        if abs(ay - by) > 0.01 { return ay > by }
        return a.boundingBox.origin.x < b.boundingBox.origin.x
    }

    var lines: [String] = []
    for o in sorted {
        guard let top = o.topCandidates(1).first, top.confidence >= minConfidence else { continue }
        lines.append(top.string)
    }
    return lines.joined(separator: "\n")
}


// MARK: - Video

func findFFmpeg() -> String? {
    // Honour the user's PATH first; their chosen ffmpeg is the one that should run.
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for dir in path.split(separator: ":") {
            let c = String(dir) + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
    }
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                      NSHomeDirectory() + "/.local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return nil
}

/// Pull only the frames where the screen actually changed, with their timestamps.
func sceneFrames(video: String, threshold: Double, maxFrames: Int) -> (dir: String, frames: [(Double, String)])? {
    guard let ff = findFFmpeg() else {
        FileHandle.standardError.write("cheapshot: ffmpeg not found in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin\n".data(using: .utf8)!)
        return nil
    }
    let dir = NSTemporaryDirectory() + "cheapshot-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: ff)
    p.arguments = ["-hide_banner", "-nostdin", "-i", video,
                   "-vf", "select=eq(n\\,0)+gt(scene\\,\(threshold)),metadata=print:file=-",
                   "-frames:v", "\(maxFrames)",
                   "\(dir)/f_%05d.png"]
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch {
        FileHandle.standardError.write("cheapshot: could not launch \(ff): \(error)\n".data(using: .utf8)!)
        return nil
    }
    var outData = Data(), errData = Data()
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    p.waitUntilExit(); g.wait()
    let data = outData
    if p.terminationStatus != 0 {
        let tail = (String(data: errData, encoding: .utf8) ?? "").split(separator: "\n").suffix(6).joined(separator: "\n")
        FileHandle.standardError.write("cheapshot: ffmpeg exited \(p.terminationStatus)\n\(tail)\n".data(using: .utf8)!)
    }

    // metadata=print emits "frame:N  pts:... pts_time:SECONDS"
    var times: [Double] = []
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        guard let r = line.range(of: "pts_time:") else { continue }
        if let t = Double(line[r.upperBound...].prefix(while: { $0 != " " })) { times.append(t) }
    }

    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".png") }.sorted()
    var frames: [(Double, String)] = []
    for (i, f) in files.enumerated() {
        frames.append((i < times.count ? times[i] : Double(i), dir + "/" + f))
    }
    return (dir, frames)
}

/// Cheap token-set overlap. Screen recordings repeat; near-identical frames are dropped.
func similarity(_ a: String, _ b: String) -> Double {
    let sa = Set(a.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    let sb = Set(b.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    if sa.isEmpty && sb.isEmpty { return 1 }
    if sa.isEmpty || sb.isEmpty { return 0 }
    return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
}

func stamp(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%02d:%02d", t / 60, t % 60)
}

// MARK: - Token accounting

func imageTokens(path: String) -> Int {
    guard let img = NSImage(contentsOfFile: path),
          let rep = img.representations.first else { return 0 }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    // Anthropic's rule of thumb, with the long-edge downscale to 1568px applied.
    var fw = Double(w), fh = Double(h)
    let maxEdge = 1568.0
    if max(fw, fh) > maxEdge { let s = maxEdge / max(fw, fh); fw *= s; fh *= s }
    return Int((fw * fh / 750.0).rounded())
}

func textTokens(_ s: String) -> Int { max(1, Int((Double(s.count) / 4.0).rounded())) }


// MARK: - Ledger

/// Append one line per run to ~/.claude/cheapshot-ledger/YYYYMMDD.tsv.
/// Same shape as the read-ledger: ISO time, then tab-separated fields.
func ledgerAppend(mode: String, inputs: Int, imageTokens: Int, textTokens: Int, redactions: Int) {
    let dir = NSHomeDirectory() + "/.claude/cheapshot-ledger"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let day = DateFormatter(); day.dateFormat = "yyyyMMdd"; day.timeZone = TimeZone(identifier: "UTC")
    let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; iso.timeZone = TimeZone(identifier: "UTC")
    let now = Date()
    let path = dir + "/" + day.string(from: now) + ".tsv"
    let saved = max(0, imageTokens - textTokens)
    let line = "\(iso.string(from: now))\t\(mode)\t\(inputs)\t\(imageTokens)\t\(textTokens)\t\(saved)\t\(redactions)\n"
    if let d = line.data(using: .utf8) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: URL(fileURLWithPath: path)) }
    }
}

func ledgerTotal() {
    let dir = NSHomeDirectory() + "/.claude/cheapshot-ledger"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".tsv") }.sorted()
    var runs = 0, imgs = 0, txt = 0, saved = 0, red = 0, inputs = 0
    for f in files {
        guard let body = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { continue }
        for line in body.split(separator: "\n") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 7 else { continue }
            runs += 1
            inputs += Int(c[2]) ?? 0; imgs += Int(c[3]) ?? 0
            txt += Int(c[4]) ?? 0; saved += Int(c[5]) ?? 0; red += Int(c[6]) ?? 0
        }
    }
    let pct = imgs > 0 ? Int(Double(saved) / Double(imgs) * 100) : 0
    print("""
    cheapshot ledger  (\(files.count) day\(files.count == 1 ? "" : "s"))
      runs           \(runs)
      inputs         \(inputs)
      image tokens   \(imgs)
      text tokens    \(txt)
      saved          \(saved)  (\(pct)%)
      redactions     \(red)
    """)
}

// MARK: - CLI

func usage() {
    print("""
    cheapshot \(VERSION) - on-device screenshot OCR for AI agents

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
if args.contains("--version") { print(VERSION); exit(0) }
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
        let text = doRedact ? redact(raw).0 : raw
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
    let (text, report) = doRedact ? redact(raw) : (raw, RedactionReport())
    let it = imageTokens(path: f), tt = textTokens(text)
    totalImageTokens += it; totalTextTokens += tt
    totalRedactions += report.counts.values.reduce(0, +)

    if asJSON {
        jsonOut.append(["file": f, "text": text, "redactions": report.counts,
                        "image_tokens": it, "text_tokens": tt])
    } else {
        if files.count > 1 { print("== \((f as NSString).lastPathComponent)") }
        print(text)
    }
}

if asJSON {
    let payload: [String: Any] = ["version": VERSION, "results": jsonOut,
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
