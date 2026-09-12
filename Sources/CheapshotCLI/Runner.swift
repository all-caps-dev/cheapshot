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
        case .video(let path): return await runVideo(opts, path: path, redactor: redactor, io: io)
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

    /// One JSON object per recognized line: 1-based number, redacted text, integer box with a
    /// top-left origin, and Vision's confidence. The box is in pixels for an image or a rendered
    /// page, and in PDF points for the text lane.
    ///
    /// The lines are redacted joined, exactly as `text` is, and split back apart, so the array is
    /// the same redaction the payload carries. Redacting each line on its own was weaker: a rule
    /// whose pattern crosses a newline redacted the document but not the array, so `text` was
    /// clean while `lines[]` still held the secret, and the two disagreed on how many lines there
    /// were. When a rule does eat a newline the split no longer lines up with the input, and then
    /// per-line redaction is the honest fallback: a custom rule may contain `\s` deliberately, and
    /// keeping `n` and the boxes attached to the right line matters more than matching `text`.
    static func lineJSON(_ lines: [RenderedLine], redactor: Redactor?) -> [[String: Any]] {
        let joined = apply(redactor, lines.map(\.text).joined(separator: "\n")).text.components(separatedBy: "\n")
        let texts = joined.count == lines.count ? joined : lines.map { apply(redactor, $0.text).text }
        return zip(lines, texts).map { l, text in
            ["n": l.n, "text": text,
             "bbox": [Int(l.bbox.minX.rounded()), Int(l.bbox.minY.rounded()), Int(l.bbox.maxX.rounded()), Int(l.bbox.maxY.rounded())],
             "confidence": Double(l.confidence)]
        }
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
        let tt = Tokens.text(text)
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
            if (f as NSString).pathExtension.lowercased() == "pdf" {
                let doc: PDFDocumentResult
                do { doc = try PDFSource.pages(of: URL(fileURLWithPath: f), range: opts.pages, minConfidence: opts.minConfidence) }
                catch {
                    failed += 1
                    results.append(["file": f, "error": "\(error)"])
                    io.err("cheapshot: \(error)\n")
                    continue
                }
                let (text, report) = apply(redactor, PDFSource.text(of: doc))
                let it = doc.pages.reduce(0) { $0 + Tokens.image(width: $1.width, height: $1.height) }
                let tt = Tokens.text(text)
                totalImage += it; totalText += tt; totalRedactions += report.total
                results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                                "source": ["path": doc.path, "sha256": doc.sha256, "pages": doc.pageCount],
                                "pages": doc.pages.map { ["n": $0.n, "lane": $0.lane.rawValue,
                                                          "width": $0.width, "height": $0.height,
                                                          "lines": lineJSON($0.lines, redactor: redactor)] as [String: Any] }])
                if !opts.json {
                    if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                    io.out(text + "\n")
                }
                continue
            }
            guard let image = ImageLoader.load(path: f) else {
                failed += 1
                results.append(["file": f, "error": "cannot read image"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            }
            let rendered: [RenderedLine]
            do { rendered = try OCR.recognizeLayout(image: image, minConfidence: opts.minConfidence) }
            catch {
                failed += 1
                results.append(["file": f, "error": "\(error)"])
                io.err("cheapshot: \(f): \(error)\n")
                continue
            }
            let (text, report) = apply(redactor, Layout.text(rendered))
            let size = ImageLoader.pixelSize(path: f) ?? (image.width, image.height)
            let it = Tokens.image(width: size.width, height: size.height), tt = Tokens.text(text)
            totalImage += it; totalText += tt; totalRedactions += report.total
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                            "lines": lineJSON(rendered, redactor: redactor)])
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

    // MARK: - video

    static func runVideo(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) async -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            if opts.json { io.out(Output.json(payload([["file": path, "error": "no such video"]], imageTokens: 0, textTokens: 0))) }
            io.err("cheapshot: no such video \(path)\n")
            return 1
        }
        let source = FFmpegFrameSource(sceneThreshold: opts.scene)
        let transcriber = VideoTranscriber(source: source, dedupe: opts.dedupe, minConfidence: opts.minConfidence, redactor: redactor)
        let t: VideoTranscript
        do { t = try await transcriber.transcribe(URL(fileURLWithPath: path), maxFrames: opts.maxFrames) }
        catch {
            if opts.json { io.out(Output.json(payload([["file": path, "error": "\(error)"]], imageTokens: 0, textTokens: 0))) }
            io.err("cheapshot: \(error)\n")
            return 1
        }
        guard t.frameCount > 0 else {
            if opts.json { io.out(Output.json(payload([["file": path, "error": "no frames extracted"]], imageTokens: 0, textTokens: 0))) }
            io.err("cheapshot: no frames extracted\n")
            return 1
        }

        var body = ""
        for s in t.segments { body += "[\(VideoTranscriber.stamp(s.time))]\n\(s.text)\n\n" }
        let tt = Tokens.text(body)
        if opts.json {
            let segs = t.segments.map { ["time": $0.time, "stamp": VideoTranscriber.stamp($0.time), "text": $0.text] as [String: Any] }
            io.out(Output.json(payload([["file": path, "text": body.trimmingCharacters(in: .whitespacesAndNewlines),
                                         "segments": segs, "frames": t.frameCount, "redactions": t.redactions.counts,
                                         "image_tokens": t.imageTokens, "text_tokens": tt]],
                                       imageTokens: t.imageTokens, textTokens: tt)))
        } else {
            io.out(body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        }
        record(LedgerEntry(mode: "video", inputs: t.frameCount, imageTokens: t.imageTokens, textTokens: tt, redactions: t.redactions.total), opts, io)
        if opts.stats {
            let saved = max(0, t.imageTokens - tt)
            let pct = t.imageTokens > 0 ? Int(Double(saved) / Double(t.imageTokens) * 100) : 0
            io.err("cheapshot: \(t.frameCount) scene frames, \(t.segments.count) distinct screens  \(t.imageTokens) image tokens -> \(tt) text tokens  (saved \(saved), \(pct)%)\n")
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
