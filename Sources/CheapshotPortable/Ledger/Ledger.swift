import Foundation
#if os(Windows)
import WinSDK
#endif

public struct LedgerEntry: Codable, Equatable {
    public var ts: String
    public var mode: String
    public var inputs: Int
    public var imageTokens: Int
    public var textTokens: Int
    public var saved: Int
    public var redactions: Int
    /// true when redaction was off for this run (--raw). Absent (nil) on a redacted run, so old
    /// lines and new redacted lines look the same on disk (#290 item 4).
    public var raw: Bool?
    /// Set only on a "passthrough" line: why the Read hook let pixels reach the model. One of
    /// ``LedgerEntry/passthroughReasons``. Never a path, so the ledger stays free of file names.
    public var passthroughReason: String?
    /// How many built-in rules were switched off for this run by a rules file or --preset (rules
    /// file v2, NOV-156). Absent (nil) when every built-in ran, so default lines are unchanged.
    public var rulesOff: Int?

    /// The reasons the hook may record. "allow" is a one-shot `cheapshot allow`, "passthrough_env"
    /// is CHEAPSHOT_PASSTHROUGH=1, "error" is any hook or binary failure, "over_cap" a PDF over the
    /// page cap, "no_text" an image with nothing recognised.
    public static let passthroughReasons = ["allow", "passthrough_env", "error", "over_cap", "no_text"]

    enum CodingKeys: String, CodingKey {
        case ts, mode, inputs, saved, redactions, raw
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
        case passthroughReason = "passthrough_reason"
        case rulesOff = "rules_off"
    }

    public init(ts: String = LedgerEntry.now(), mode: String, inputs: Int, imageTokens: Int, textTokens: Int, redactions: Int,
                raw: Bool? = nil, passthroughReason: String? = nil, rulesOff: Int? = nil) {
        self.ts = ts; self.mode = mode; self.inputs = inputs
        self.imageTokens = imageTokens; self.textTokens = textTokens
        self.saved = max(0, imageTokens - textTokens); self.redactions = redactions
        self.raw = raw; self.passthroughReason = passthroughReason; self.rulesOff = rulesOff
    }

    /// A zero-token line that records one hook pass-through. Kept out of the savings totals.
    public static func passthrough(reason: String, ts: String = LedgerEntry.now()) -> LedgerEntry {
        LedgerEntry(ts: ts, mode: "passthrough", inputs: 1, imageTokens: 0, textTokens: 0, redactions: 0, passthroughReason: reason)
    }

    var isPassthrough: Bool { passthroughReason != nil }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func now() -> String { isoFormatter.string(from: Date()) }
    var date: Date? { LedgerEntry.isoFormatter.date(from: ts) }
}

public struct LedgerSummary: Codable, Equatable {
    public var days: Int, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int
    /// Runs with redaction off, and Read hook pass-throughs (pixels reached the model). #290 item 4.
    public var rawRuns: Int, passthroughs: Int
    enum CodingKeys: String, CodingKey {
        case days, runs, inputs, saved, redactions, percent, passthroughs
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
        case rawRuns = "raw_runs"
    }
    public init(days: Int, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int,
                rawRuns: Int = 0, passthroughs: Int = 0) {
        self.days = days; self.runs = runs; self.inputs = inputs; self.imageTokens = imageTokens
        self.textTokens = textTokens; self.saved = saved; self.redactions = redactions; self.percent = percent
        self.rawRuns = rawRuns; self.passthroughs = passthroughs
    }
}

/// One row of `--ledger --by-mode`. Same counters as the whole-ledger summary, scoped to the
/// runs of one mode, because the modes are not comparable: a video row counts frames the agent
/// would never have uploaded, an image row counts screenshots it genuinely would have.
public struct LedgerModeSummary: Codable, Equatable {
    public var mode: String, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int
    enum CodingKeys: String, CodingKey {
        case mode, runs, inputs, saved, redactions, percent
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
    }
    public init(mode: String, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int) {
        self.mode = mode; self.runs = runs; self.inputs = inputs; self.imageTokens = imageTokens
        self.textTokens = textTokens; self.saved = saved; self.redactions = redactions; self.percent = percent
    }
}

public struct LedgerError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// One JSON object per line. Appends are a single write(2) on an O_APPEND descriptor so
/// concurrent runs never interleave.
public struct Ledger {
    public static let fileName = "ledger.jsonl"

    public let url: URL
    public init(at url: URL) { self.url = url }

    /// Location rule from the spec: $CHEAPSHOT_HOME, else ~/Library/Application Support/cheapshot.
    /// The CLI never writes the App Group container: outside the group, macOS 15 prompts the user.
    public static func resolveURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory(),
                                  fileManager: FileManager = .default) -> URL {
        if let h = environment["CHEAPSHOT_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h).appendingPathComponent(fileName)
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/cheapshot/\(fileName)")
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    public func append(_ entry: LedgerEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try Ledger.encoder.encode(entry)
        data.append(0x0A)
        #if os(Windows)
        // Windows has no POSIX open(2) that Swift can call with a mode (the CRT's _open is
        // variadic). FILE_APPEND_DATA without FILE_WRITE_DATA makes every WriteFile land at the
        // end of the file in one piece, the same guarantee O_APPEND gives below. Unverified until a
        // windows-core run shows LedgerTests passing: that step is not gating, so a green job alone
        // does not prove this path; read the step's own result.
        let path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_APPEND_DATA), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard handle != INVALID_HANDLE_VALUE else {
            throw LedgerError(message: "cannot open \(url.path): Windows error \(GetLastError())")
        }
        defer { CloseHandle(handle) }
        var written: DWORD = 0
        let ok = data.withUnsafeBytes { WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil) }
        guard ok, Int(written) == data.count else { throw LedgerError(message: "short write to \(url.path)") }
        #else
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw LedgerError(message: "cannot open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw LedgerError(message: "short write to \(url.path)") }
        #endif
    }

    public func entries() throws -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let body = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return body.split(separator: "\n").compactMap { try? decoder.decode(LedgerEntry.self, from: Data($0.utf8)) }
    }

    /// Every entry, or only those inside the last `days` days.
    func entries(days: Int?) throws -> [LedgerEntry] {
        let all = try entries()
        guard let days = days else { return all }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return all.filter { ($0.date ?? .distantPast) >= cutoff }
    }

    public func summary(days: Int? = nil) throws -> LedgerSummary {
        let window = try entries(days: days)
        // Pass-through lines carry no tokens; counting them as runs would dilute the savings.
        let all = window.filter { !$0.isPassthrough }
        let dayCount = Set(all.map { String($0.ts.prefix(10)) }).count
        let img = all.reduce(0) { $0 + $1.imageTokens }
        let txt = all.reduce(0) { $0 + $1.textTokens }
        let saved = all.reduce(0) { $0 + $1.saved }
        return LedgerSummary(days: dayCount, runs: all.count,
                             inputs: all.reduce(0) { $0 + $1.inputs },
                             imageTokens: img, textTokens: txt, saved: saved,
                             redactions: all.reduce(0) { $0 + $1.redactions },
                             percent: img > 0 ? Int(Double(saved) / Double(img) * 100) : 0,
                             rawRuns: all.filter { $0.raw == true }.count,
                             passthroughs: window.count - all.count)
    }

    /// The same window split by mode, biggest saving first. Ties break on the mode name so the
    /// order is stable across runs.
    public func summaryByMode(days: Int? = nil) throws -> [LedgerModeSummary] {
        var byMode: [String: [LedgerEntry]] = [:]
        for e in try entries(days: days) where !e.isPassthrough { byMode[e.mode, default: []].append(e) }
        return byMode.map { mode, rows in
            let img = rows.reduce(0) { $0 + $1.imageTokens }
            let saved = rows.reduce(0) { $0 + $1.saved }
            return LedgerModeSummary(mode: mode, runs: rows.count,
                                     inputs: rows.reduce(0) { $0 + $1.inputs },
                                     imageTokens: img,
                                     textTokens: rows.reduce(0) { $0 + $1.textTokens },
                                     saved: saved,
                                     redactions: rows.reduce(0) { $0 + $1.redactions },
                                     percent: img > 0 ? Int(Double(saved) / Double(img) * 100) : 0)
        }.sorted { $0.saved != $1.saved ? $0.saved > $1.saved : $0.mode < $1.mode }
    }

    static func pad(_ s: String, _ width: Int, right: Bool = true) -> String {
        s.count >= width ? s : (right ? String(repeating: " ", count: width - s.count) + s
                                      : s + String(repeating: " ", count: width - s.count))
    }

    public func summaryTextByMode(_ s: LedgerSummary, _ modes: [LedgerModeSummary]) -> String {
        let widths = [8, 7, 9, 14, 13, 14, 5, 11]
        func row(_ cells: [String]) -> String {
            "  " + zip(cells, widths).enumerated()
                .map { i, cw in Ledger.pad(cw.0, cw.1, right: i > 0) }.joined(separator: " ")
        }
        var out = "cheapshot ledger  (\(s.days) day\(s.days == 1 ? "" : "s"), by mode)\n"
        out += row(["mode", "runs", "inputs", "image tokens", "text tokens", "saved", "%", "redactions"]) + "\n"
        for m in modes {
            out += row([m.mode, "\(m.runs)", "\(m.inputs)", "\(m.imageTokens)",
                        "\(m.textTokens)", "\(m.saved)", "\(m.percent)", "\(m.redactions)"]) + "\n"
        }
        out += row(["TOTAL", "\(s.runs)", "\(s.inputs)", "\(s.imageTokens)",
                    "\(s.textTokens)", "\(s.saved)", "\(s.percent)", "\(s.redactions)"]) + "\n\n"
        return out
    }

    public func summaryText(_ s: LedgerSummary) -> String {
        // The two #290 counters print only when non-zero, so a ledger with neither reads as before.
        let extra = s.rawRuns + s.passthroughs > 0
            ? "  raw runs       \(s.rawRuns)\n  passthroughs   \(s.passthroughs)\n" : ""
        return """
        cheapshot ledger  (\(s.days) day\(s.days == 1 ? "" : "s"))
          runs           \(s.runs)
          inputs         \(s.inputs)
          image tokens   \(s.imageTokens)
          text tokens    \(s.textTokens)
          saved          \(s.saved)  (\(s.percent)%)
          redactions     \(s.redactions)
        \(extra)
        """
    }
}
