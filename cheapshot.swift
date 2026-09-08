// cheapshot - on-device screenshot OCR for AI agents.
// Turns screenshots into redacted text so agents read words, not pixels.
// Apple Vision. No network. No API cost.

import Foundation
import AppKit
import Vision

let VERSION = "0.2.0"

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
    Rule("CARD",        #"\b\d(?:[ \-]?\d){12,18}\b"#, []),
    Rule("PHONE",       #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, []),
    Rule("TOKEN",       #"(?=[A-Za-z0-9_\-+/=.]*[a-z])(?=[A-Za-z0-9_\-+/=.]*[A-Z])[A-Za-z0-9_\-+/=.]*[A-Za-z0-9_\-+/=.]{20,}"#, []),
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

// MARK: - CLI

func usage() {
    print("""
    ocra \(VERSION) - on-device screenshot OCR for AI agents

    USAGE
      cheapshot <file.png> [more.png ...]
      cheapshot --newest <dir> [n]
      cheapshot --cleanshot [n]

    OPTIONS
      --raw             do not redact (redaction is ON by default)
      --json            emit JSON
      --stats           print token savings to stderr
      --min-conf <f>    confidence floor, default 0.3
      --version
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { usage(); exit(0) }
if args.contains("--version") { print(VERSION); exit(0) }

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
if let c = popValue("--min-conf"), let f = Float(c) { minConf = f }

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

var totalImageTokens = 0, totalTextTokens = 0
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

if showStats {
    let saved = max(0, totalImageTokens - totalTextTokens)
    let pct = totalImageTokens > 0 ? Int(Double(saved) / Double(totalImageTokens) * 100) : 0
    let msg = "cheapshot: \(files.count - failed) image(s)  \(totalImageTokens) image tokens -> \(totalTextTokens) text tokens  (saved \(saved), \(pct)%)\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
}

exit(failed > 0 && failed == files.count ? 1 : 0)
