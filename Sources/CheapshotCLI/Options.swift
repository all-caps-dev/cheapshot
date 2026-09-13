import Foundation

public struct UsageError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct Options: Equatable {
    public enum Command: Equatable {
        case help, version
        case ledger(json: Bool, migrate: Bool, days: Int?)
        case allow(path: String)         // one-shot hook escape hatch, see plugin/hooks/cheapshot-read.sh
        case text(path: String)          // "-" means stdin
        case video(path: String)
        case files([String])
        case newest(dir: String, count: Int)
        case cleanshot(count: Int)
    }

    public var command: Command
    public var redact = true, json = false, stats = false, noLedger = false
    public var minConfidence: Float = 0.3
    public var scene = 0.25, maxFrames = 200, dedupe = 0.90
    public var rulesPath: String? = nil
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

    public static func parse(_ args: [String]) throws -> Options {
        if args.isEmpty || args.contains("-h") || args.contains("--help") { return Options(command: .help) }
        if args.contains("--version") { return Options(command: .version) }
        if args.first == "allow" {
            guard args.count >= 2 else { throw UsageError(message: "allow needs a path") }
            guard args.count == 2 else { throw UsageError(message: "allow takes exactly one path") }
            return Options(command: .allow(path: args[1]))
        }

        var o = Options(command: .files([]))
        var positional: [String] = []
        var newest: (dir: String, count: Int)? = nil
        var cleanshot: Int? = nil
        var text: String? = nil
        var video: String? = nil
        var ledger = false, migrate = false
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
            switch a {
            case "--raw":       o.redact = false
            case "--json":      o.json = true
            case "--stats":     o.stats = true
            case "--no-ledger": o.noLedger = true
            case "--ledger":    ledger = true
            case "--migrate":   migrate = true
            case "--days":      days = try positiveInt(a)
            case "--min-conf":  o.minConfidence = Float(try unitNumber(a))
            case "--scene":     o.scene = try unitNumber(a)
            case "--max-frames": o.maxFrames = try positiveInt(a)
            case "--dedupe":    o.dedupe = try unitNumber(a)
            case "--rules":     o.rulesPath = try value(a)
            case "--pages":     o.pages = try parsePages(try value(a))
            case "--text":      text = try value(a)
            case "--video":     video = try value(a)
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

        if ledger { o.command = .ledger(json: o.json, migrate: migrate, days: days); return o }
        if migrate { throw UsageError(message: "--migrate needs --ledger") }
        if days != nil { throw UsageError(message: "--days needs --ledger") }
        if let t = text { o.command = .text(path: t); return o }
        if let v = video { o.command = .video(path: v); return o }
        if let n = newest { o.command = .newest(dir: n.dir, count: n.count); return o }
        if let n = cleanshot { o.command = .cleanshot(count: n); return o }
        guard !positional.isEmpty else { throw UsageError(message: "no input files") }
        o.command = .files(positional)
        return o
    }
}
