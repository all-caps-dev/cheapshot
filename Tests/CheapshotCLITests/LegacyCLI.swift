// Swift. A frozen copy of the CLI's image, PDF and text pipeline as it was at origin/main 1c0876a
// (v0.6.0; first frozen at 7c5f2c9, then brought up to v0.6.0's OCR cold-start retry and its
// ocr_status, retried and screenshot_like fields when the branch was rebased onto it)
// (Sources/CheapshotCLI/Runner.swift, the lines the native app plan's step 2 moved into
// CheapshotCore), kept only as the "before" side of PipelineParityTests.
//
// Do not fix or tidy this file. Its whole value is that it does not change: the parity tests
// run every fixture through it and through today's CLI in the same process, and require the
// same stdout, stderr, exit code and ledger lines. It even loads images with NSImage, as the
// CLI did before step 1, so the comparison covers both steps.
//
// Only the commands step 2 touches are here: image and PDF files, --newest and --text.
import Foundation
import AppKit
import CheapshotCore
@testable import CheapshotCLI

enum LegacyCLI {
    static func run(arguments: [String], io: CLIIO) -> Int32 {
        let opts: Options
        do { opts = try Options.parse(arguments) }
        catch let e as UsageError { io.err("cheapshot: \(e.message)\ntry: cheapshot --help\n"); return 2 }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        let redactor: Redactor?
        do { redactor = try makeRedactor(opts, io) }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        switch opts.command {
        case .text(let path): return runText(opts, path: path, redactor: redactor, io: io)
        case .files(let paths): return runImages(opts, paths: paths, redactor: redactor, io: io)
        case .newest(let dir, let n): return runNewest(opts, dir: dir, count: n, redactor: redactor, io: io)
        default: preconditionFailure("LegacyCLI covers image, PDF, --newest and --text runs only")
        }
    }

    // The NSImage loader CheapshotCore used before step 1.
    enum NSImageLoader {
        static func load(path: String) -> CGImage? {
            guard let img = NSImage(contentsOfFile: path) else { return nil }
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        static func pixelSize(path: String) -> (width: Int, height: Int)? {
            guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first else { return nil }
            return (rep.pixelsWide, rep.pixelsHigh)
        }
    }

    static func runNewest(_ opts: Options, dir: String, count: Int, redactor: Redactor?, io: CLIIO) -> Int32 {
        let paths: [String]
        do { paths = try CLI.newest(in: dir, count: count) }
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

    static func rulesURL(_ opts: Options, _ io: CLIIO) -> (url: URL, named: Bool)? {
        if let p = opts.rulesPath { return (URL(fileURLWithPath: p), true) }
        if let p = io.environment["CHEAPSHOT_RULES"], !p.isEmpty { return (URL(fileURLWithPath: p), true) }
        let fallback = Ledger.resolveURL(environment: io.environment, home: io.home)
            .deletingLastPathComponent().appendingPathComponent("rules.json")
        return FileManager.default.fileExists(atPath: fallback.path) ? (fallback, false) : nil
    }

    static func makeRedactor(_ opts: Options, _ io: CLIIO) throws -> Redactor? {
        guard opts.redact else { return nil }
        guard let rules = rulesURL(opts, io) else { return Redactor() }
        do {
            return Redactor(customRules: try RuleFile.load(rules.url))
        } catch where !rules.named {
            io.err("cheapshot: warning: ignoring \(rules.url.path): \(error); using built-in rules only\n")
            return Redactor()
        }
    }

    static func apply(_ redactor: Redactor?, _ text: String) -> (text: String, report: RedactionReport) {
        redactor?.redact(text) ?? (text, RedactionReport())
    }

    static func lineJSON(_ lines: [RenderedLine], redactor: Redactor?) -> [[String: Any]] {
        let joined = apply(redactor, lines.map(\.text).joined(separator: "\n")).text.components(separatedBy: "\n")
        let texts = joined.count == lines.count ? joined : lines.map { apply(redactor, $0.text).text }
        return zip(lines, texts).map { l, text in
            ["n": l.n, "text": text,
             "bbox": [Int(l.bbox.minX.rounded()), Int(l.bbox.minY.rounded()), Int(l.bbox.maxX.rounded()), Int(l.bbox.maxY.rounded())],
             "confidence": Double(l.confidence)]
        }
    }

    static func emit(_ object: Any, _ io: CLIIO) -> Bool {
        do { io.out(try Output.json(object)); return true }
        catch { io.err("cheapshot: \(error)\n"); return false }
    }

    static func payload(_ results: [[String: Any]], imageTokens: Int, textTokens: Int) -> [String: Any] {
        ["version": cheapshotVersion, "results": results, "image_tokens": imageTokens, "text_tokens": textTokens]
    }

    static func savings(imageTokens: Int, textTokens: Int) -> (saved: Int, pct: Int) {
        let saved = max(0, imageTokens - textTokens)
        let pct = imageTokens > 0 ? Int(Double(saved) / Double(imageTokens) * 100) : 0
        return (saved, pct)
    }

    static func statsLine(inputs: Int, noun: String, imageTokens: Int, textTokens: Int) -> String {
        let (saved, pct) = savings(imageTokens: imageTokens, textTokens: textTokens)
        return "cheapshot: \(inputs) \(noun)  \(imageTokens) image tokens -> \(textTokens) text tokens  (saved \(saved), \(pct)%)\n"
    }

    static func ledger(_ io: CLIIO) -> Ledger {
        Ledger(at: Ledger.resolveURL(environment: io.environment, home: io.home))
    }

    static func record(_ entry: LedgerEntry, _ opts: Options, _ io: CLIIO) {
        guard !opts.noLedger else { return }
        var entry = entry
        if !opts.redact { entry.raw = true }
        do { try ledger(io).append(entry) } catch { io.err("cheapshot: ledger not written: \(error)\n") }
    }

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

    struct RunTotals {
        var inputs = 0, imageTokens = 0, textTokens = 0, redactions = 0
        mutating func add(imageTokens it: Int, textTokens tt: Int, redactions r: Int) {
            inputs += 1; imageTokens += it; textTokens += tt; redactions += r
        }
    }

    static func runImages(_ opts: Options, paths: [String], redactor: Redactor?, io: CLIIO) -> Int32 {
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
                do { doc = try PDFSource.pages(of: URL(fileURLWithPath: f), range: opts.pages, minConfidence: opts.minConfidence,
                                                 forceOCR: opts.forceOCR) }
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
            guard let image = NSImageLoader.load(path: f) else {
                failed += 1
                results.append(["file": f, "error": "cannot read image"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            }
            let checked: OCR.CheckedLayout
            do { checked = try OCR.recognizeLayoutChecked(image: image, minConfidence: opts.minConfidence) }
            catch {
                failed += 1
                results.append(["file": f, "error": "\(error)"])
                io.err("cheapshot: \(f): \(error)\n")
                continue
            }
            let rendered = checked.lines
            if checked.retried && checked.status == .empty {
                io.err("cheapshot: \(f): no text found after a retry, though it looks like a screenshot\n")
            }
            let (text, report) = apply(redactor, Layout.text(rendered))
            let size = NSImageLoader.pixelSize(path: f) ?? (image.width, image.height)
            let it = Tokens.image(width: size.width, height: size.height), tt = Tokens.text(text)
            images.add(imageTokens: it, textTokens: tt, redactions: report.total)
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                            "lines": lineJSON(rendered, redactor: redactor),
                            // "empty" with "retried": true is a screenshot-like image that still read blank
                            // (a likely cold-start OCR failure); "empty" without a retry is a photo or a
                            // small image. Callers must not treat the first like the second.
                            "ocr_status": checked.status.rawValue, "retried": checked.retried,
                            "screenshot_like": checked.screenshotLike])
            if !opts.json {
                if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                io.out(text + "\n")
            }
        }

        let totalImage = pdfs.imageTokens + images.imageTokens
        let totalText = pdfs.textTokens + images.textTokens
        if opts.json, !emit(payload(results, imageTokens: totalImage, textTokens: totalText), io) { return 1 }
        let ok = paths.count - failed
        for (mode, t) in [("pdf", pdfs), ("image", images)] where t.inputs > 0 {
            record(LedgerEntry(mode: mode, inputs: t.inputs, imageTokens: t.imageTokens,
                               textTokens: t.textTokens, redactions: t.redactions), opts, io)
        }
        if opts.stats {
            let isPDF = paths.map { ($0 as NSString).pathExtension.lowercased() == "pdf" }
            let hasPDF = isPDF.contains(true), hasImage = isPDF.contains(false)
            let noun = hasPDF ? (hasImage ? "input(s)" : "pdf(s)") : "image(s)"
            io.err(statsLine(inputs: ok, noun: noun, imageTokens: totalImage, textTokens: totalText))
        }
        return failed > 0 ? 1 : 0
    }
}
