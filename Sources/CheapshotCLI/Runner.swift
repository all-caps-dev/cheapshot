import Foundation
import AppKit
import CryptoKit
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
        case .ledger(let json, let migrate, let days, let byMode):
            return runLedger(json: json, migrate: migrate, days: days, byMode: byMode, io: io)
        case .allow(let path): return runAllow(path: path, io: io)
        case .notePassthrough(let reason):
            record(.passthrough(reason: reason), opts, io)
            return 0
        default: break
        }

        let redactor: Redactor?
        do { redactor = try makeRedactor(opts, io) }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        switch opts.command {
        case .help, .version, .ledger, .allow, .notePassthrough: preconditionFailure("handled above")
        case .mask(let path, let out): return runMask(opts, path: path, out: out, redactor: redactor ?? Redactor(), io: io)
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

    /// Which rules file applies, first match wins: --rules, then $CHEAPSHOT_RULES, then rules.json
    /// next to the ledger when it exists. Before #290 item 4 only --rules worked, so the Read hook
    /// and the MCP server (which never pass --rules) ran built-in rules only. `named` is true for
    /// the first two: a file someone named on purpose that is missing or bad is an error (exit 2).
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
            // The default file broke (a typo, or the app mid-write). Keep the built-in redaction
            // rather than failing every run, which would send the Read hook's pixels through.
            io.err("cheapshot: warning: ignoring \(rules.url.path): \(error); using built-in rules only\n")
            return Redactor()
        }
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

    /// Tokens not spent by reading text instead of the image, floored at zero, and that as a
    /// truncated percent of the image cost. Zero image tokens is zero saved, not a division.
    static func savings(imageTokens: Int, textTokens: Int) -> (saved: Int, pct: Int) {
        let saved = max(0, imageTokens - textTokens)
        let pct = imageTokens > 0 ? Int(Double(saved) / Double(imageTokens) * 100) : 0
        return (saved, pct)
    }

    static func statsLine(inputs: Int, noun: String, imageTokens: Int, textTokens: Int) -> String {
        let (saved, pct) = savings(imageTokens: imageTokens, textTokens: textTokens)
        return "cheapshot: \(inputs) \(noun)  \(imageTokens) image tokens -> \(textTokens) text tokens  (saved \(saved), \(pct)%)\n"
    }

    // MARK: - ledger

    static func ledger(_ io: CLIIO) -> Ledger {
        Ledger(at: Ledger.resolveURL(environment: io.environment, home: io.home))
    }

    static func record(_ entry: LedgerEntry, _ opts: Options, _ io: CLIIO) {
        guard !opts.noLedger else { return }
        var entry = entry
        if !opts.redact { entry.raw = true }   // #290 item 4: a raw run is visible in the ledger
        do { try ledger(io).append(entry) } catch { io.err("cheapshot: ledger not written: \(error)\n") }
    }

    static func runLedger(json: Bool, migrate: Bool, days: Int?, byMode: Bool = false, io: CLIIO) -> Int32 {
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
            let s = try l.summary(days: days)
            if json {
                var o: [String: Any] = ["days": s.days, "runs": s.runs, "inputs": s.inputs, "image_tokens": s.imageTokens,
                                        "text_tokens": s.textTokens, "saved": s.saved, "redactions": s.redactions,
                                        "percent": s.percent, "path": l.url.path,
                                        "raw_runs": s.rawRuns, "passthroughs": s.passthroughs]
                if let days = days { o["window_days"] = days }
                if byMode {
                    o["modes"] = try l.summaryByMode(days: days).map { m in
                        ["mode": m.mode, "runs": m.runs, "inputs": m.inputs, "image_tokens": m.imageTokens,
                         "text_tokens": m.textTokens, "saved": m.saved, "redactions": m.redactions,
                         "percent": m.percent]
                    }
                }
                io.out(try Output.json(o))
            } else if byMode {
                io.out(l.summaryTextByMode(s, try l.summaryByMode(days: days)))
            } else {
                io.out(l.summaryText(s))
            }
            return 0
        } catch { io.err("cheapshot: \(error)\n"); return 1 }
    }

    // MARK: - allow

    /// Appends "<expiry>\t<path>" to $TMPDIR/cheapshot-allow. The Claude Code hook consumes the
    /// entry on the next Read of that path and lets the pixels through once. Five minutes is long
    /// enough for "run allow, then Read again" and short enough that a forgotten entry does nothing.
    static let allowSeconds = 300

    /// Same resolution as the hook's `${TMPDIR:-/tmp}`: an unset or empty TMPDIR means /tmp.
    static func allowFile(_ io: CLIIO) -> URL {
        let tmp = io.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return URL(fileURLWithPath: tmp).appendingPathComponent("cheapshot-allow")
    }

    /// Image types `allow` re-encodes into a metadata-free copy (NOV-117). Anything else (a PDF)
    /// is allowed as the file itself, as before.
    static let strippedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp"]

    static func runAllow(path: String, io: CLIIO) -> Int32 {
        // #290 item 3: allow is a person's decision. An agent's shell tool has no terminal on stdin,
        // so a model steered by text it read cannot approve its own raw access this way. Not a hard
        // wall: anything running as the user can still fake a terminal (script(1)) or write the file.
        guard io.isInteractive else {
            io.err("cheapshot: allow must be run by a person in a terminal (needs a foreground terminal on stdin and stdout)\n")
            return 2
        }
        guard strippedExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            guard let absolute = writeAllowEntry(path, io) else { return 1 }
            io.out("cheapshot: allowed \(absolute) for 5 minutes\n")
            return 0
        }
        // NOV-117: an image the person approves still must not carry its GPS position, camera
        // make and model or capture time to the model. Write the pixels (upright, re-encoded as
        // PNG, no metadata) to a scratch copy and allow the original path with that copy and its
        // SHA-256. The hook then points the Read at a fresh copy of the copy (`updatedInput`),
        // so the agent asks for the original and gets the stripped pixels. If the copy cannot be
        // made, nothing is allowed: never fall back to the raw file.
        let stripped: (data: Data, width: Int, height: Int)
        do { stripped = try Masker.strippedPNG(path: absolutePath(path)) }
        catch { io.err("cheapshot: allow: \(error); nothing was allowed\n"); return 1 }
        let dest = scratchURL(for: path, folder: "cheapshot-allowed", tag: "allowed", io)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try stripped.data.write(to: dest, options: .withoutOverwriting)
        } catch { io.err("cheapshot: allow: cannot write \(dest.path): \(error.localizedDescription); nothing was allowed\n"); return 1 }
        let digest = SHA256.hash(data: stripped.data).map { String(format: "%02x", $0) }.joined()
        guard let absolute = writeAllowEntry(path, io, sha256: digest, copy: dest.path) else {
            try? FileManager.default.removeItem(at: dest)
            return 1
        }
        io.out("cheapshot: allowed \(absolute) for 5 minutes\n")
        io.out("cheapshot: the agent sees a copy with the pixels only (\(stripped.width)x\(stripped.height), upright, no location, camera or date metadata): \(dest.path)\n")
        return 0
    }

    /// Absolute, standardised form of `path`, the form the hook compares against.
    static func absolutePath(_ path: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath
        return ((path.hasPrefix("/") ? path : cwd + "/" + path) as NSString).standardizingPath
    }

    /// Appends one allow line for `path` and returns the absolute path it wrote, or nil after
    /// printing why it could not. Shared by `allow` (a person, raw pixels) and `mask` (the masked
    /// copy only, which needs no person: the risky lines are already painted over).
    /// `sha256`, when given (mask), is written as a third field: the hook then honours the entry
    /// only while the file is not a symlink and still hashes to it, so swapping the masked copy
    /// for another file after `mask` does not unlock raw pixels (PR #18 review).
    /// `copy`, when given (allow of an image, NOV-117), is a fourth field: the stripped copy the
    /// hook shows in place of `path`; `sha256` is then the copy's hash, not the original's.
    static func writeAllowEntry(_ path: String, _ io: CLIIO, sha256: String? = nil, copy: String? = nil) -> String? {
        let absolute = absolutePath(path)
        // A newline, CR or tab in the path would let one call forge extra allow lines (for
        // example a far-future entry for another file with no hash). Refuse any control
        // character (PR #18 second review).
        let hasControl = { (s: String) in s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        guard !hasControl(absolute), !hasControl(copy ?? "") else {
            io.err("cheapshot: refusing to allow a path with a control character in it\n"); return nil
        }
        let expiry = Int(Date().timeIntervalSince1970) + allowSeconds
        // "<expiry>\t<path>[\t<sha256>[\t<copy>]]"
        let fields = [String(expiry), absolute] + (sha256.map { [$0] } ?? []) + (copy.map { [$0] } ?? [])
        let line = Data((fields.joined(separator: "\t") + "\n").utf8)
        let url = allowFile(io)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { io.err("cheapshot: cannot open \(url.path): \(String(cString: strerror(errno)))\n"); return nil }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { io.err("cheapshot: short write to \(url.path)\n"); return nil }
        return absolute
    }

    // MARK: - mask

    /// Where a mask goes when --out is not given: $TMPDIR/cheapshot-masked/<name>-masked-<time>-<rand>.png.
    /// Never next to the source, so a screenshot folder does not fill with copies, and never the
    /// source itself.
    static func defaultMaskURL(for path: String, _ io: CLIIO) -> URL {
        scratchURL(for: path, folder: "cheapshot-masked", tag: "masked", io)
    }

    /// $TMPDIR/<folder>/<name>-<tag>-<time>-<rand>.png: the masked copy, or the stripped copy
    /// `allow` writes for an image (NOV-117).
    static func scratchURL(for path: String, folder: String, tag: String, _ io: CLIIO) -> URL {
        let tmp = io.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent(folder)
        // Keep the name readable but shell-friendly: macOS screenshot names carry spaces and U+202F.
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = String(stem.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "_" }.prefix(60))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let rand = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        return dir.appendingPathComponent("\(safe)-\(tag)-\(f.string(from: Date()))-\(rand).png")
    }

    static func runMask(_ opts: Options, path: String, out: String?, redactor: Redactor, io: CLIIO) -> Int32 {
        func fail(_ message: String) -> Int32 {
            if opts.json { _ = emit(["version": cheapshotVersion, "file": path, "error": message], io) }
            io.err("cheapshot: \(message)\n")
            return 1
        }
        guard FileManager.default.fileExists(atPath: path) else { return fail("no such file \(path)") }
        guard (path as NSString).pathExtension.lowercased() != "pdf" else { return fail("mask works on images, not PDFs: \(path)") }

        let result: MaskResult
        do {
            let image = try Masker.loadPixels(path: path)
            result = try Masker.mask(image, redactor: redactor, minConfidence: opts.minConfidence)
        } catch { return fail("\(error)") }

        let dest = out.map { URL(fileURLWithPath: absolutePath($0)) } ?? defaultMaskURL(for: path, io)
        guard dest.standardizedFileURL.path != URL(fileURLWithPath: absolutePath(path)).standardizedFileURL.path else {
            return fail("--out is the source image; mask never overwrites it")
        }
        let digest: String
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let png = try Masker.pngData(result.image)
            // withoutOverwriting: an existing file at --out (the source, or anything else) is an error.
            try png.write(to: dest, options: .withoutOverwriting)
            digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        } catch { return fail("cannot write \(dest.path): \(error.localizedDescription)") }

        // The same one-shot, five-minute entry `cheapshot allow` writes, for the masked copy only.
        // If the allow line cannot be written, remove the copy so no orphan is left behind, and
        // report through fail() so a --json caller still gets its error object.
        guard let allowed = writeAllowEntry(dest.path, io, sha256: digest) else {
            try? FileManager.default.removeItem(at: dest)
            return fail("could not allow the masked copy; removed \(dest.path)")
        }

        let redacted = result.boxes.filter { $0.reason == .redacted }.count
        let low = result.boxes.count - redacted
        if opts.json {
            let boxes: [[String: Any]] = result.boxes.map { b in
                let r = Masker.painted(b.rect, width: result.image.width, height: result.image.height)
                return ["reason": b.reason.rawValue,
                        "bbox": [Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY)]]
            }
            guard emit(["version": cheapshotVersion, "file": path, "masked": allowed, "boxes": boxes,
                        "box_count": result.boxes.count, "redactions": result.report.counts,
                        "width": result.image.width, "height": result.image.height,
                        "rounds": result.rounds, "allowed_seconds": allowSeconds], io) else { return 1 }
        } else {
            let counts = result.report.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            io.out("masked: \(allowed)\n")
            io.out("boxes: \(result.boxes.count) (\(redacted) redacted, \(low) low-confidence)\n")
            io.out("redactions: \(counts.isEmpty ? "none" : counts)\n")
            io.out("cheapshot: allowed the masked copy for 5 minutes; Read the path above. Text Vision did not see is not masked.\n")
        }
        return 0
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
        VideoTranscriber(source: FFmpegFrameSource(sceneThreshold: opts.scene, times: opts.frameTimes),
                         dedupe: opts.dedupe,
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
            let (saved, pct) = savings(imageTokens: t.imageTokens, textTokens: tt)
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
