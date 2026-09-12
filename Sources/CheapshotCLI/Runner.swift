import Foundation
import AppKit
import CheapshotCore

public enum CLI {
    public static func run(arguments: [String], io: CLIIO = .standard) async -> Int32 {
        let opts: Options
        do { opts = try Options.parse(arguments) }
        catch let e as UsageError { io.err("cheapshot: \(e.message)\ntry: cheapshot --help\n"); return 2 }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        let redactor: Redactor?
        do { redactor = try makeRedactor(opts) }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        switch opts.command {
        case .help:    io.out(Output.usage()); return 0
        case .version: io.out(cheapshotVersion + "\n"); return 0
        case .ledger(let json, let migrate): return runLedger(json: json, migrate: migrate, io: io)
        case .text(let path): return runText(opts, path: path, redactor: redactor, io: io)
        case .video(let path): return runVideo(opts, path: path, redactor: redactor, io: io)
        case .files(let paths): return runImages(opts, paths: paths, redactor: redactor, io: io)
        case .newest(let dir, let n): return runImages(opts, paths: newest(in: dir, count: n), redactor: redactor, io: io)
        case .cleanshot(let n): return runImages(opts, paths: newest(in: cleanshotDir(home: io.home), count: n), redactor: redactor, io: io)
        }
    }

    // MARK: - Setup

    static func makeRedactor(_ opts: Options) throws -> Redactor? {
        guard opts.redact else { return nil }
        guard let path = opts.rulesPath else { return Redactor() }
        return Redactor(customRules: try RuleFile.load(URL(fileURLWithPath: path)))
    }

    static func apply(_ redactor: Redactor?, _ text: String) -> (text: String, report: RedactionReport) {
        redactor?.redact(text) ?? (text, RedactionReport())
    }

    static func payload(_ results: [[String: Any]], imageTokens: Int, textTokens: Int) -> [String: Any] {
        ["version": cheapshotVersion, "results": results, "image_tokens": imageTokens, "text_tokens": textTokens]
    }

    static func statsLine(inputs: Int, noun: String, imageTokens: Int, textTokens: Int) -> String {
        let saved = max(0, imageTokens - textTokens)
        let pct = imageTokens > 0 ? Int(Double(saved) / Double(imageTokens) * 100) : 0
        return "cheapshot: \(inputs) \(noun)  \(imageTokens) image tokens -> \(textTokens) text tokens  (saved \(saved), \(pct)%)\n"
    }

    // MARK: - ledger

    static func ledger(_ io: CLIIO) -> Ledger {
        Ledger(at: Ledger.resolveURL(environment: io.environment, home: io.home))
    }

    static func record(_ entry: LedgerEntry, _ opts: Options, _ io: CLIIO) {
        guard !opts.noLedger else { return }
        do { try ledger(io).append(entry) } catch { io.err("cheapshot: ledger not written: \(error)\n") }
    }

    static func runLedger(json: Bool, migrate: Bool, io: CLIIO) -> Int32 {
        let l = ledger(io)
        do {
            if migrate {
                let n = try l.migrate(fromTSVDirectory: Ledger.defaultTSVDirectory(home: io.home))
                io.out("cheapshot: imported \(n) ledger line(s) into \(l.url.path)\n")
                return 0
            }
            let s = try l.summary()
            if json {
                io.out(Output.json(["days": s.days, "runs": s.runs, "inputs": s.inputs, "image_tokens": s.imageTokens,
                                    "text_tokens": s.textTokens, "saved": s.saved, "redactions": s.redactions,
                                    "percent": s.percent, "path": l.url.path]))
            } else {
                io.out(l.summaryText(s))
            }
            return 0
        } catch { io.err("cheapshot: \(error)\n"); return 1 }
    }

    // MARK: - --text

    static func runText(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) -> Int32 {
        let raw: String
        if path == "-" {
            raw = io.readStdin()
        } else {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                if opts.json { io.out(Output.json(payload([["file": path, "error": "cannot read"]], imageTokens: 0, textTokens: 0))) }
                io.err("cheapshot: cannot read \(path)\n")
                return 1
            }
            raw = s
        }
        let input = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let (text, report) = apply(redactor, input)
        let tt = Tokens_text(text)
        if opts.json {
            io.out(Output.json(payload([["file": path, "text": text, "redactions": report.counts,
                                         "image_tokens": 0, "text_tokens": tt]], imageTokens: 0, textTokens: tt)))
        } else {
            io.out(text + "\n")
        }
        if opts.stats { io.err("cheapshot: \(report.total) redaction(s), \(tt) text tokens\n") }
        return 0
    }

    // MARK: - images

    static func runImages(_ opts: Options, paths: [String], redactor: Redactor?, io: CLIIO) -> Int32 {
        guard !paths.isEmpty else { io.err("cheapshot: no input images\n"); return 2 }
        var results: [[String: Any]] = []
        var totalImage = 0, totalText = 0, totalRedactions = 0, failed = 0

        for f in paths {
            guard FileManager.default.fileExists(atPath: f) else {
                failed += 1
                results.append(["file": f, "error": "no such file"])
                io.err("cheapshot: no such file \(f)\n")
                continue
            }
            guard let raw = ocr(path: f, minConfidence: opts.minConfidence) else {
                failed += 1
                results.append(["file": f, "error": "cannot read image"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            }
            let (text, report) = apply(redactor, raw)
            let it = imageTokens(path: f), tt = Tokens_text(text)
            totalImage += it; totalText += tt; totalRedactions += report.total
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt])
            if !opts.json {
                if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                io.out(text + "\n")
            }
        }

        if opts.json { io.out(Output.json(payload(results, imageTokens: totalImage, textTokens: totalText))) }
        let ok = paths.count - failed
        if ok > 0 {
            record(LedgerEntry(mode: "image", inputs: ok, imageTokens: totalImage, textTokens: totalText, redactions: totalRedactions), opts, io)
        }
        if opts.stats { io.err(statsLine(inputs: ok, noun: "image(s)", imageTokens: totalImage, textTokens: totalText)) }
        return failed > 0 ? 1 : 0
    }

    // MARK: - video (Task 11 replaces the body with VideoTranscriber)

    static func runVideo(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else { io.err("cheapshot: no such video \(path)\n"); return 2 }
        guard let (tmp, frames) = sceneFrames(video: path, threshold: opts.scene, maxFrames: opts.maxFrames), !frames.isEmpty else {
            io.err("cheapshot: no frames extracted\n"); return 1
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }   // runs now: this is a function, not exit(0)

        var kept: [(Double, String)] = []
        var lastText = ""
        var frameImageTokens = 0, redactions = 0
        for (t, f) in frames {
            frameImageTokens += imageTokens(path: f)
            guard let raw = ocr(path: f, minConfidence: opts.minConfidence) else { continue }
            let (text, report) = apply(redactor, raw)
            redactions += report.total
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if similarity(trimmed, lastText) >= opts.dedupe { continue }
            kept.append((t, trimmed)); lastText = trimmed
        }
        var body = ""
        for (t, text) in kept { body += "[\(stamp(t))]\n\(text)\n\n" }
        io.out(body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let tt = Tokens_text(body)
        record(LedgerEntry(mode: "video", inputs: frames.count, imageTokens: frameImageTokens, textTokens: tt, redactions: redactions), opts, io)
        if opts.stats {
            io.err("cheapshot: \(frames.count) scene frames, \(kept.count) distinct screens  "
                   + statsLine(inputs: frames.count, noun: "frame(s)", imageTokens: frameImageTokens, textTokens: tt).dropFirst("cheapshot: ".count).description)
        }
        return 0
    }

    // MARK: - input discovery

    static func newest(in dir: String, count: Int) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let exts = ["png", "jpg", "jpeg", "webp", "gif", "pdf"]
        let candidates = items.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        let withDates: [(String, Date)] = candidates.compactMap {
            let p = (dir as NSString).appendingPathComponent($0)
            let d = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil
            return d.map { (p, $0) }
        }
        return withDates.sorted { $0.1 > $1.1 }.prefix(count).map { $0.0 }
    }

    /// CleanShot's export folder, else ~/Desktop (macOS's own screenshot default).
    static func cleanshotDir(home: String) -> String {
        UserDefaults(suiteName: "pl.maketheweb.cleanshotx")?.string(forKey: "exportPath") ?? (home + "/Desktop")
    }
}

// Until Task 10 moves the estimators into Tokens, alias the Phase 0 function under a name
// that will not collide with the local variables named textTokens.
func Tokens_text(_ s: String) -> Int { textTokens(s) }
