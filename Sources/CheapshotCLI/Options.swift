import Foundation
import CheapshotCore

public struct UsageError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct Options: Equatable {
    public enum Command: Equatable {
        case help, version
        case ledger(json: Bool, migrate: Bool, days: Int?, byMode: Bool)
        case allow(path: String)         // one-shot hook escape hatch, see plugin/hooks/cheapshot-read.sh
        case mask(path: String, out: String?)  // masked copy for an agent to look at (NOV-95)
        case notePassthrough(reason: String)  // the hook records a pass-through in the ledger (#290 item 4)
        case text(path: String)          // "-" means stdin
        case video(path: String)
        case files([String])
        case newest(dir: String, count: Int)
        case cleanshot(count: Int)
        case listRules(json: Bool)       // the rule catalog with each rule on or off (NOV-156)
    }

    public var command: Command
    public var redact = true, json = false, stats = false, noLedger = false
    /// Every PDF page goes to the scan lane, even when its text layer checks out.
    public var forceOCR = false
    public var minConfidence: Float = 0.3
    public var scene = 0.25, maxFrames = 200, dedupe = 0.90
    /// Explicit frame times for a --video run. nil means scene detection picks the frames.
    public var frameTimes: [TimeInterval]? = nil
    public var rulesPath: String? = nil
    /// --preset: replaces the rules file's preset for this run (rules file v2, NOV-156).
    public var preset: String? = nil
    /// --all-rules: ignore every toggle and preset in the rules file; all built-in rules run.
    public var allRules = false
    /// Set by the runner once the rules are loaded, never by the parser: which built-ins are off
    /// this run. Nil on a run with every built-in on, which is every default run.
    public var rulesMark: RulesMark? = nil
    public var pages: ClosedRange<Int>? = nil

    public init(command: Command) { self.command = command }

    /// True for a token that reads as an option rather than a path: a dash followed by
    /// something that is neither another dash nor a digit. A bare "-" (stdin) and a
    /// negative-looking token stay positional, because those are still just filenames.
    private static func isShortOption(_ token: String) -> Bool {
        guard token.first == "-", let second = token.dropFirst().first else { return false }
        return second != "-" && !("0"..."9").contains(second)
    }

    public static func parsePages(_ s: String) throws -> ClosedRange<Int> {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts.last!),
              lo >= 1, hi >= lo else {
            throw UsageError(message: "--pages: expected N or N-M with N >= 1, got \(s)")
        }
        return lo...hi
    }

    /// SS, SS.s, MM:SS or HH:MM:SS. Minutes and seconds stay under 60 so a typo like 1:75
    /// is an error instead of a silently shifted timestamp.
    public static func parseTimestamp(_ s: String) throws -> TimeInterval {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { throw UsageError(message: "--frames-at: not a timestamp: \(s)") }
        var total: TimeInterval = 0
        for (i, part) in parts.enumerated() {
            guard let n = Double(part), n.isFinite, n >= 0 else {
                throw UsageError(message: "--frames-at: not a timestamp: \(s)")
            }
            // Only the last field may carry a fraction; earlier fields are whole and under 60.
            if i < parts.count - 1, n != n.rounded(.down) || n >= 60 {
                throw UsageError(message: "--frames-at: not a timestamp: \(s)")
            }
            if parts.count > 1, i > 0, n >= 60 {
                throw UsageError(message: "--frames-at: not a timestamp: \(s)")
            }
            total = total * 60 + n
        }
        return total
    }

    /// yt-cc writes meta.json with `chapters: [{"t": seconds, "title": ...}]` and a
    /// `duration_string` of "MM:SS" or "HH:MM:SS". One frame per chapter, at the chapter's
    /// midpoint: the start of a chapter is a title card, the middle is the result on screen.
    public static func chapterMidpoints(metaPath: String) throws -> [TimeInterval] {
        guard let data = FileManager.default.contents(atPath: metaPath) else {
            throw UsageError(message: "--chapters: cannot read \(metaPath)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError(message: "--chapters: not JSON: \(metaPath)")
        }
        let chapters = (root["chapters"] as? [[String: Any]]) ?? []
        let starts = chapters.compactMap { ($0["t"] as? NSNumber)?.doubleValue }
        guard !starts.isEmpty else { throw UsageError(message: "--chapters: no chapters in \(metaPath)") }
        // The final chapter ends at the video's duration when we know it, otherwise 60 s on.
        var end = starts[starts.count - 1] + 60
        if let d = root["duration_string"] as? String, let parsed = try? parseTimestamp(d), parsed > starts.last! {
            end = parsed
        }
        return starts.enumerated().map { i, t in
            let next = i + 1 < starts.count ? starts[i + 1] : end
            return (t + next) / 2
        }
    }

    /// `cheapshot mask [--out <file.png>] [--min-conf <f>] [--rules <file>] [--all-rules] [--json] [--] <image>`.
    /// No --preset: a mask is a copy for an agent and always runs every built-in rule (Q5 A, see
    /// `CLI.togglePolicy`); --all-rules is accepted and changes nothing.
    /// Its own small parser, so a flag that makes no sense here (--raw above all: a mask with
    /// redaction off would paint nothing) is a usage error instead of being silently accepted.
    static func parseMask(_ args: [String]) throws -> Options {
        var o = Options(command: .help)
        var out: String? = nil
        var positional: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { throw UsageError(message: "mask: \(flag) needs a value") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            if a == "--" { positional.append(contentsOf: args[(i + 1)...]); break }
            switch a {
            case "--out":
                let v = try value(a)
                // A control character in the path could forge allow lines (PR #18 second review).
                guard !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw UsageError(message: "mask: --out must not contain control characters")
                }
                out = v
            case "--json":     o.json = true
            case "--rules":    o.rulesPath = try value(a)
            case "--all-rules": o.allRules = true
            case "--min-conf":
                let v = try value(a)
                guard let n = Float(v), n.isFinite, n >= 0, n <= 1 else {
                    throw UsageError(message: "mask: --min-conf must be between 0 and 1: \(v)")
                }
                // Raise only: nobody approves a mask run, so it may never mask less than the
                // default (PR #18 review: --min-conf 0 drops every low-confidence box).
                guard n >= Options(command: .help).minConfidence else {
                    throw UsageError(message: "mask: --min-conf can only raise the floor (at least \(Options(command: .help).minConfidence)): \(v)")
                }
                o.minConfidence = n
            default:
                if a.hasPrefix("-") { throw UsageError(message: "mask: unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }
        guard positional.count == 1 else { throw UsageError(message: "mask takes exactly one image") }
        if let out = out, (out as NSString).pathExtension.lowercased() != "png" {
            throw UsageError(message: "mask: --out must end in .png (the copy is always a lossless PNG)")
        }
        o.command = .mask(path: positional[0], out: out)
        o.noLedger = true   // a mask is not a savings run; the hook records the Read of the copy
        return o
    }

    public static func parse(_ args: [String]) throws -> Options {
        // Only tokens before "--" can be options, so a file named "--help" after it stays a file (#290).
        let flags = args.firstIndex(of: "--").map { Array(args[..<$0]) } ?? args
        if args.isEmpty || flags.contains("-h") || flags.contains("--help") { return Options(command: .help) }
        if flags.contains("--version") { return Options(command: .version) }
        if args.first == "allow" {
            guard args.count >= 2 else { throw UsageError(message: "allow needs a path") }
            guard args.count == 2 else { throw UsageError(message: "allow takes exactly one path") }
            guard !args[1].hasPrefix("-") else { throw UsageError(message: "unknown option \(args[1])") }
            return Options(command: .allow(path: args[1]))
        }
        if args.first == "mask" { return try parseMask(Array(args.dropFirst())) }
        if args.first == "--note-passthrough" {
            // Only a fixed set of reasons, never a path, so the ledger cannot collect file names.
            guard args.count == 2, LedgerEntry.passthroughReasons.contains(args[1]) else {
                throw UsageError(message: "--note-passthrough takes one of: " + LedgerEntry.passthroughReasons.joined(separator: ", "))
            }
            return Options(command: .notePassthrough(reason: args[1]))
        }

        var o = Options(command: .files([]))
        var positional: [String] = []
        var newest: (dir: String, count: Int)? = nil
        var cleanshot: Int? = nil
        var text: String? = nil
        var video: String? = nil
        var ledger = false, migrate = false, byMode = false, listRules = false
        var days: Int? = nil
        var i = 0

        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
            i += 1
            return args[i]
        }
        /// A finite fraction in 0...1, bounds inclusive.
        func unitNumber(_ flag: String) throws -> Double {
            let v = try value(flag)
            guard let n = Double(v) else { throw UsageError(message: "\(flag): not a number: \(v)") }
            guard n.isFinite, n >= 0, n <= 1 else {
                throw UsageError(message: "\(flag): must be between 0 and 1: \(v)")
            }
            return n
        }
        /// A count of at least 1.
        func positiveInt(_ flag: String) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v) else { throw UsageError(message: "\(flag): not a number: \(v)") }
            guard n >= 1 else { throw UsageError(message: "\(flag): must be >= 1: \(v)") }
            return n
        }
        /// The next token when it is a count. An integer below 1 is an error rather than a
        /// silent fall-through to a path, so --newest -3 cannot reach the runner.
        func nextCount(_ flag: String) throws -> Int? {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--"), let n = Int(args[i + 1]) else { return nil }
            guard n >= 1 else { throw UsageError(message: "\(flag): count must be >= 1: \(args[i + 1])") }
            return n
        }

        while i < args.count {
            let a = args[i]
            // "--" ends option parsing: every token after it is a file, even "--raw" or "--text".
            // The MCP server puts it before the paths a model hands in, so a path can never act
            // as a flag and switch redaction off (#290).
            if a == "--" {
                positional.append(contentsOf: args[(i + 1)...])
                break
            }
            switch a {
            case "--raw":       o.redact = false
            case "--json":      o.json = true
            case "--stats":     o.stats = true
            case "--no-ledger": o.noLedger = true
            case "--force-ocr": o.forceOCR = true
            case "--ledger":    ledger = true
            case "--migrate":   migrate = true
            case "--by-mode":   byMode = true
            case "--days":      days = try positiveInt(a)
            case "--min-conf":  o.minConfidence = Float(try unitNumber(a))
            case "--scene":     o.scene = try unitNumber(a)
            case "--max-frames": o.maxFrames = try positiveInt(a)
            case "--dedupe":    o.dedupe = try unitNumber(a)
            case "--rules":     o.rulesPath = try value(a)
            case "--preset":    o.preset = try value(a)
            case "--all-rules": o.allRules = true
            case "--list-rules": listRules = true
            case "--pages":     o.pages = try parsePages(try value(a))
            case "--text":      text = try value(a)
            case "--video":     video = try value(a)
            case "--frames-at":
                let raw = try value(a)
                let times = try raw.split(separator: ",").map { try parseTimestamp(String($0).trimmingCharacters(in: .whitespaces)) }
                guard !times.isEmpty else { throw UsageError(message: "--frames-at: no timestamps") }
                o.frameTimes = Array(Set(times)).sorted()
            case "--chapters":
                o.frameTimes = try chapterMidpoints(metaPath: try value(a))
            case "--newest":
                var dir = ".", n = 1
                if let k = try nextCount(a) {
                    n = k; i += 1
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--"), !isShortOption(args[i + 1]) {
                    dir = args[i + 1]; i += 1
                    if let k = try nextCount(a) { n = k; i += 1 }
                }
                newest = (dir, n)
            case "--cleanshot":
                var n = 1
                if let k = try nextCount(a) { n = k; i += 1 }
                cleanshot = n
            default:
                if a.hasPrefix("--") || isShortOption(a) { throw UsageError(message: "unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }

        // A mode flag runs its own input, so a leftover file would be silently dropped.
        // Report the clash instead of guessing which one the caller meant.
        let mode: String? = ledger ? "--ledger"
            : listRules ? "--list-rules"
            : text != nil ? "--text"
            : video != nil ? "--video"
            : newest != nil ? "--newest"
            : cleanshot != nil ? "--cleanshot"
            : nil
        if let m = mode, !positional.isEmpty {
            throw UsageError(message: "files cannot be combined with \(m): \(positional.joined(separator: " "))")
        }

        if listRules {
            // Report a clash instead of dropping the other flag (the rule for modes above).
            let other: [(Bool, String)] = [(ledger, "--ledger"), (text != nil, "--text"), (video != nil, "--video"),
                                           (newest != nil, "--newest"), (cleanshot != nil, "--cleanshot"),
                                           (o.frameTimes != nil, "--frames-at or --chapters"), (migrate, "--migrate"),
                                           (days != nil, "--days"), (byMode, "--by-mode"), (!o.redact, "--raw")]
            if let clash = other.first(where: { $0.0 }) {
                throw UsageError(message: "--list-rules cannot be combined with \(clash.1)")
            }
            o.command = .listRules(json: o.json); return o
        }
        if ledger { o.command = .ledger(json: o.json, migrate: migrate, days: days, byMode: byMode); return o }
        if migrate { throw UsageError(message: "--migrate needs --ledger") }
        if days != nil { throw UsageError(message: "--days needs --ledger") }
        if byMode { throw UsageError(message: "--by-mode needs --ledger") }
        if let t = text { o.command = .text(path: t); return o }
        if let v = video { o.command = .video(path: v); return o }
        if o.frameTimes != nil { throw UsageError(message: "--frames-at needs --video") }
        if let n = newest { o.command = .newest(dir: n.dir, count: n.count); return o }
        if let n = cleanshot { o.command = .cleanshot(count: n); return o }
        guard !positional.isEmpty else { throw UsageError(message: "no input files") }
        o.command = .files(positional)
        return o
    }
}

/// Which built-in rules a run switched off, for the weakened-run marks: one stderr line, a
/// `rules` key in --json and `rules_off` on the ledger line (plan 4.4).
public struct RulesMark: Equatable {
    public let preset: String
    /// Built-in names, in catalog order.
    public let disabled: [String]
    /// Built-in names still on but catching less, each with the reason ("no MICR cue").
    public let partial: [String: String]
    public init(preset: String, disabled: [String], partial: [String: String] = [:]) {
        self.preset = preset; self.disabled = disabled; self.partial = partial
    }

    /// The --json `rules` value. `partial` appears only when a rule is partial.
    var json: [String: Any] {
        var j: [String: Any] = ["preset": preset, "disabled": disabled]
        if !partial.isEmpty { j["partial"] = partial }
        return j
    }

    /// The stderr line.
    var notice: String {
        let n = disabled.count
        var line = "cheapshot: \(n) built-in rule\(n == 1 ? " is" : "s are") off (preset \(preset))"
        for name in partial.keys.sorted() { line += "; \(name) is partial (\(partial[name]!))" }
        return line + "\n"
    }
}
