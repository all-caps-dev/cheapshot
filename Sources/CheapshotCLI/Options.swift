import Foundation

public struct UsageError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct Options: Equatable {
    public enum Command: Equatable {
        case help, version
        case ledger(json: Bool, migrate: Bool)
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

        var o = Options(command: .files([]))
        var positional: [String] = []
        var newest: (dir: String, count: Int)? = nil
        var cleanshot: Int? = nil
        var text: String? = nil
        var video: String? = nil
        var ledger = false, migrate = false
        var i = 0

        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
            i += 1
            return args[i]
        }
        func number<T: LosslessStringConvertible>(_ flag: String, _ type: T.Type) throws -> T {
            let v = try value(flag)
            guard let n = T(v) else { throw UsageError(message: "\(flag): not a number: \(v)") }
            return n
        }
        func nextIsInt() -> Int? {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return Int(args[i + 1])
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
            case "--min-conf":  o.minConfidence = try number(a, Float.self)
            case "--scene":     o.scene = try number(a, Double.self)
            case "--max-frames": o.maxFrames = try number(a, Int.self)
            case "--dedupe":    o.dedupe = try number(a, Double.self)
            case "--rules":     o.rulesPath = try value(a)
            case "--pages":     o.pages = try parsePages(try value(a))
            case "--text":      text = try value(a)
            case "--video":     video = try value(a)
            case "--newest":
                var dir = ".", n = 1
                if let k = nextIsInt() {
                    n = k; i += 1
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    dir = args[i + 1]; i += 1
                    if let k = nextIsInt() { n = k; i += 1 }
                }
                newest = (dir, n)
            case "--cleanshot":
                var n = 1
                if let k = nextIsInt() { n = k; i += 1 }
                cleanshot = n
            default:
                if a.hasPrefix("--") { throw UsageError(message: "unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }

        if ledger { o.command = .ledger(json: o.json, migrate: migrate); return o }
        if migrate { throw UsageError(message: "--migrate needs --ledger") }
        if let t = text { o.command = .text(path: t); return o }
        if let v = video { o.command = .video(path: v); return o }
        if let n = newest { o.command = .newest(dir: n.dir, count: n.count); return o }
        if let n = cleanshot { o.command = .cleanshot(count: n); return o }
        guard !positional.isEmpty else { throw UsageError(message: "no input files") }
        o.command = .files(positional)
        return o
    }
}
