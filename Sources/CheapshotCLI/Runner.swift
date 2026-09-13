import Foundation
import AppKit
import CheapshotCore

public enum CLI {
    public static func run(arguments: [String], io: CLIIO = .standard) async -> Int32 {
        let opts: Options
        do { opts = try Options.parse(arguments) }
        catch let e as UsageError { io.err("cheapshot: \(e.message)\ntry: cheapshot --help\n"); return 2 }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        // Help, version and the ledger never redact, so a bad --rules file must not stop them.
        switch opts.command {
        case .help:    io.out(Output.usage()); return 0
        case .version: io.out(cheapshotVersion + "\n"); return 0
        case .ledger(let json, let migrate): return runLedger(json: json, migrate: migrate, io: io)
        default: break
        }

        let redactor: Redactor?
        do { redactor = try makeRedactor(opts) }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        switch opts.command {
        case .help, .version, .ledger: preconditionFailure("handled above")
        case .text(let path): return runText(opts, path: path, redactor: redactor, io: io)
        case .video(let path): return await runVideo(opts, path: path, redactor: redactor, io: io)
        case .files(let paths): return runImages(opts, paths: paths, redactor: redactor, io: io)
        case .newest(let dir, let n): return runNewest(opts, dir: dir, count: n, redactor: redactor, io: io)
        case .cleanshot(let n): return runNewest(opts, dir: cleanshotDir(home: io.home), count: n, redactor: redactor, io: io)
        }
    }

    /// The directory is the input here, so an unreadable one is an input failure that names it,
    /// not a usage error about missing images.
    static func runNewest(_ opts: Options, dir: String, count: Int, redactor: Redactor?, io: CLIIO) -> Int32 {
        let paths: [String]
        do { paths = try newest(in: dir, count: count) }
        catch {
            let message = "cannot read directory: \(error.localizedDescription)"
            if opts.json { _ = emit(payload([["file": dir, "error": message]], imageTokens: 0, textTokens: 0), io) }
            io.err("cheapshot: cannot read directory \(dir): \(error.localizedDescription)\n")
            return 1
        }
        guard !paths.isEmpty else {
            let message = "no images or PDFs in \(dir)"
            if opts.json { _ = emit(payload([["file": dir, "error": message]], imageTokens: 0, textTokens: 0), io) }
            io.err("cheapshot: \(message)\n")
            return 1
        }
        return runImages(opts, paths: paths, redactor: redactor, io: io)
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

    /// Writes the --json envelope, or the serialization failure to stderr. False means the run
    /// must exit 1: a payload that cannot be emitted is a failed run, not an empty one.
    static func emit(_ object: Any, _ io: CLIIO) -> Bool {
        do { io.out(try Output.json(object)); return true }
        catch { io.err("cheapshot: \(error)\n"); return false }
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
                let dir = Ledger.defaultTSVDirectory(home: io.home)
                // "imported 0" on its own could not tell an earlier migrate from an empty or
                // missing TSV directory, and only the second is worth retrying after a restore.
                guard !FileManager.default.fileExists(atPath: l.migrationMarker.path) else {
                    io.out("cheapshot: ledger already migrated from \(dir.path) (marker \(l.migrationMarker.path))\n")
                    return 0
                }
                let n = try l.migrate(fromTSVDirectory: dir)
                io.out("cheapshot: imported \(n) ledger line(s) into \(l.url.path)\n")
                if n == 0 {
                    let why = FileManager.default.fileExists(atPath: dir.path) ? "no TSV lines found in" : "no TSV directory at"
                    io.out("cheapshot: \(why) \(dir.path); nothing marked, run --migrate again after restoring them\n")
                }
                return 0
            }
            let s = try l.summary()
            if json {
                io.out(try Output.json(["days": s.days, "runs": s.runs, "inputs": s.inputs, "image_tokens": s.imageTokens,
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
                if opts.json { _ = emit(payload([["file": path, "error": "cannot read"]], imageTokens: 0, textTokens: 0), io) }
                io.err("cheapshot: cannot read \(path)\n")
                return 1
            }
            raw = s
        }
        let input = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let (text, report) = apply(redactor, input)
        let tt = Tokens.text(text)
        if opts.json {
            guard emit(payload([["file": path, "text": text, "redactions": report.counts,
                                 "image_tokens": 0, "text_tokens": tt]], imageTokens: 0, textTokens: tt), io) else { return 1 }
        } else {
            io.out(text + "\n")
        }
        if opts.stats { io.err("cheapshot: \(report.total) redaction(s), \(tt) text tokens\n") }
        return 0
    }

    // MARK: - images

    /// One kind of input's running totals. PDFs and images are counted apart because they mean
    /// different things in the ledger: an image line is a measured saving, a PDF line is an
    /// estimate of what reading the pages as images would have cost.
    struct RunTotals {
        var inputs = 0, imageTokens = 0, textTokens = 0, redactions = 0
        mutating func add(imageTokens it: Int, textTokens tt: Int, redactions r: Int) {
            inputs += 1; imageTokens += it; textTokens += tt; redactions += r
        }
    }

    static func runImages(_ opts: Options, paths: [String], redactor: Redactor?, io: CLIIO) -> Int32 {
        // Only the PDF branch reads --pages; on any other input it was accepted and ignored.
        if opts.pages != nil, let f = paths.first(where: { ($0 as NSString).pathExtension.lowercased() != "pdf" }) {
            io.err("cheapshot: --pages applies to PDF input only, not \(f)\ntry: cheapshot --help\n")
            return 2
        }
        var results: [[String: Any]] = []
        var pdfs = RunTotals(), images = RunTotals()
        var failed = 0

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
                pdfs.add(imageTokens: it, textTokens: tt, redactions: report.total)
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
            images.add(imageTokens: it, textTokens: tt, redactions: report.total)
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                            "lines": lineJSON(rendered, redactor: redactor)])
            if !opts.json {
                if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                io.out(text + "\n")
            }
        }

        let totalImage = pdfs.imageTokens + images.imageTokens
        let totalText = pdfs.textTokens + images.textTokens
        if opts.json, !emit(payload(results, imageTokens: totalImage, textTokens: totalText), io) { return 1 }
        let ok = paths.count - failed
        // One line per kind present, so a PDF run never reports itself as measured image savings.
        for (mode, t) in [("pdf", pdfs), ("image", images)] where t.inputs > 0 {
            record(LedgerEntry(mode: mode, inputs: t.inputs, imageTokens: t.imageTokens,
                               textTokens: t.textTokens, redactions: t.redactions), opts, io)
        }
        if opts.stats {
            // From the inputs asked for, not the ones that succeeded, so a PDF run that fails
            // entirely still says pdf(s).
            let isPDF = paths.map { ($0 as NSString).pathExtension.lowercased() == "pdf" }
            let hasPDF = isPDF.contains(true), hasImage = isPDF.contains(false)
            let noun = hasPDF ? (hasImage ? "input(s)" : "pdf(s)") : "image(s)"
            io.err(statsLine(inputs: ok, noun: noun, imageTokens: totalImage, textTokens: totalText))
        }
        return failed > 0 ? 1 : 0
    }

    // MARK: - video

    /// The ffmpeg-backed transcriber the CLI runs with. Tests pass their own to `runVideo` so a
    /// video run needs neither ffmpeg nor a fixture clip.
    static func ffmpegTranscriber(_ opts: Options, _ redactor: Redactor?) -> VideoTranscriber {
        VideoTranscriber(source: FFmpegFrameSource(sceneThreshold: opts.scene), dedupe: opts.dedupe,
                         minConfidence: opts.minConfidence, redactor: redactor)
    }

    static func runVideo(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO,
                         transcriber: (Options, Redactor?) -> VideoTranscriber = ffmpegTranscriber) async -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            if opts.json { _ = emit(payload([["file": path, "error": "no such video"]], imageTokens: 0, textTokens: 0), io) }
            io.err("cheapshot: no such video \(path)\n")
            return 1
        }
        let transcriber = transcriber(opts, redactor)
        let t: VideoTranscript
        do { t = try await transcriber.transcribe(URL(fileURLWithPath: path), maxFrames: opts.maxFrames) }
        catch {
            if opts.json { _ = emit(payload([["file": path, "error": "\(error)"]], imageTokens: 0, textTokens: 0), io) }
            io.err("cheapshot: \(error)\n")
            return 1
        }
        guard t.frameCount > 0 else {
            if opts.json { _ = emit(payload([["file": path, "error": "no frames extracted"]], imageTokens: 0, textTokens: 0), io) }
            io.err("cheapshot: no frames extracted\n")
            return 1
        }

        var body = ""
        for s in t.segments { body += "[\(VideoTranscriber.stamp(s.time))]\n\(s.text)\n\n" }
        let tt = Tokens.text(body)
        if opts.json {
            let segs = t.segments.map { ["time": $0.time, "stamp": VideoTranscriber.stamp($0.time), "text": $0.text] as [String: Any] }
            guard emit(payload([["file": path, "text": body.trimmingCharacters(in: .whitespacesAndNewlines),
                                 "segments": segs, "frames": t.frameCount, "failed_frames": t.failedFrames,
                                 "redactions": t.redactions.counts,
                                 "image_tokens": t.imageTokens, "text_tokens": tt]],
                               imageTokens: t.imageTokens, textTokens: tt), io) else { return 1 }
        } else {
            io.out(body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        }
        record(LedgerEntry(mode: "video", inputs: t.frameCount, imageTokens: t.imageTokens, textTokens: tt, redactions: t.redactions.total), opts, io)
        if opts.stats {
            let saved = max(0, t.imageTokens - tt)
            let pct = t.imageTokens > 0 ? Int(Double(saved) / Double(t.imageTokens) * 100) : 0
            // A failed frame was never read, so it is in neither count above; name it or the
            // line under-reports what was skipped.
            let failed = t.failedFrames > 0 ? ", \(t.failedFrames) failed" : ""
            io.err("cheapshot: \(t.frameCount) scene frames\(failed), \(t.segments.count) distinct screens  \(t.imageTokens) image tokens -> \(tt) text tokens  (saved \(saved), \(pct)%)\n")
        }
        return 0
    }

    // MARK: - input discovery

    static func newest(in dir: String, count: Int) throws -> [String] {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: dir)
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
