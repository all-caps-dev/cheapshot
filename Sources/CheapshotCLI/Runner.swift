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

    /// The redactor for a run, or nil with --raw. Which rules file applies and what happens when
    /// it is broken live in CheapshotCore (`Pipeline.rulesSource`, `Pipeline.redactor`), so the
    /// app picks rules the same way. Before #290 item 4 only --rules worked, so the Read hook and
    /// the MCP server (which never pass --rules) ran built-in rules only. A file named with
    /// --rules or $CHEAPSHOT_RULES that is missing or bad throws here, and the run exits 2.
    static func makeRedactor(_ opts: Options, _ io: CLIIO) throws -> Redactor? {
        guard opts.redact else { return nil }
        let rules = Pipeline.rulesSource(explicitPath: opts.rulesPath, environment: io.environment, home: io.home)
        return try Pipeline.redactor(rules: rules) { io.err("cheapshot: warning: \($0)\n") }
    }

    /// One JSON object per recognized line: 1-based number, redacted text, integer box with a
    /// top-left origin, and Vision's confidence. The box is in pixels for an image or a rendered
    /// page, and in PDF points for the text lane. `lines` must already be redacted
    /// (`Pipeline.redactLines`, which the Pipeline read functions call). The label is required so
    /// a caller holding raw OCR lines cannot pick this overload by accident (PR #22 review).
    static func lineJSON(alreadyRedacted lines: [RenderedLine]) -> [[String: Any]] {
        lines.map { l in
            ["n": l.n, "text": l.text,
             "bbox": [Int(l.bbox.minX.rounded()), Int(l.bbox.minY.rounded()), Int(l.bbox.maxX.rounded()), Int(l.bbox.maxY.rounded())],
             "confidence": Double(l.confidence)]
        }
    }

    /// Redacts `lines` the way the document text is redacted, then formats them as above.
    static func lineJSON(_ lines: [RenderedLine], redactor: Redactor?) -> [[String: Any]] {
        lineJSON(alreadyRedacted: Pipeline.redactLines(lines, with: redaction(redactor)))
    }

    /// The CLI's redactor is nil for --raw and nothing else (`makeRedactor`). This is the one
    /// place that turns that nil into the Pipeline's explicit `.raw`.
    static func redaction(_ redactor: Redactor?) -> Pipeline.Redaction {
        guard let redactor = redactor else { return .raw }
        return .redact(redactor)
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

    /// See `Pipeline.savings`.
    static func savings(imageTokens: Int, textTokens: Int) -> (saved: Int, pct: Int) {
        Pipeline.savings(imageTokens: imageTokens, textTokens: textTokens)
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
        // #290 item 4: a raw run is visible in the ledger.
        let entry = Pipeline.ledgerEntry(entry, redacted: opts.redact)
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
        let stripped: (data: Data, width: Int, height: Int, frames: Int)
        do { stripped = try Masker.strippedPNG(path: absolutePath(path)) }
        catch { io.err("cheapshot: allow: \(error); nothing was allowed\n"); return 1 }
        let dest = scratchURL(for: path, folder: "cheapshot-allowed", tag: "allowed", io)
        let dir = dest.deletingLastPathComponent()
        // The copy is the person's unredacted pixels: a private folder, a 0600 file, and stale
        // copies from earlier allows (used, or never used and expired) are swept first. The
        // hook also deletes a copy as soon as its entry is used or expires.
        if let why = ensurePrivateDir(dir) { io.err("cheapshot: allow: \(why); nothing was allowed\n"); return 1 }
        sweepStale(in: dir, olderThan: TimeInterval(allowSeconds + 60))
        if let why = writePrivateFile(stripped.data, to: dest) {
            io.err("cheapshot: allow: cannot write \(dest.path): \(why); nothing was allowed\n"); return 1
        }
        let digest = SHA256.hash(data: stripped.data).map { String(format: "%02x", $0) }.joined()
        guard let absolute = writeAllowEntry(path, io, sha256: digest, copy: dest.path) else {
            try? FileManager.default.removeItem(at: dest)
            return 1
        }
        io.out("cheapshot: allowed \(absolute) for 5 minutes\n")
        let frames = stripped.frames > 1 ? ", first frame of \(stripped.frames) only" : ""
        io.out("cheapshot: the agent sees a copy, pixels re-encoded as an 8-bit sRGB PNG (\(stripped.width)x\(stripped.height), upright\(frames), no location, camera or date metadata): \(dest.path)\n")
        return 0
    }

    /// Creates `dir` with mode 0700, or checks an existing one: it must be a real directory (not
    /// a symlink, checked with lstat), owned by this user, mode 0700. Anything else is refused
    /// rather than repaired, since another user or a planted link may own it. nil means ready.
    static func ensurePrivateDir(_ dir: URL) -> String? {
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            guard errno == ENOENT else { return "cannot check \(dir.path): \(String(cString: strerror(errno)))" }
            // mkdir ignores bits the umask clears, so set the mode again after.
            guard mkdir(dir.path, 0o700) == 0 || errno == EEXIST else {
                return "cannot create \(dir.path): \(String(cString: strerror(errno)))"
            }
            guard lstat(dir.path, &st) == 0 else { return "cannot check \(dir.path)" }
            if (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() { chmod(dir.path, 0o700); st.st_mode = (st.st_mode & S_IFMT) | 0o700 }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "\(dir.path) is not a plain directory (a symlink or a file)" }
        guard st.st_uid == getuid() else { return "\(dir.path) belongs to another user" }
        // A looser folder this user owns is refused, not repaired, but the message gives the fix.
        guard (st.st_mode & 0o777) == 0o700 else {
            // Single-quoted for the shell, so a TMPDIR with spaces still pastes as one argument.
            let quoted = "'" + dir.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return "\(dir.path) has mode \(String(st.st_mode & 0o777, radix: 8)), not 700; to fix it, run: chmod 700 \(quoted)"
        }
        return nil
    }

    /// Writes `data` to a new file with mode 0600. O_EXCL refuses an existing file and O_NOFOLLOW
    /// a symlink, so nothing already there is overwritten or followed. nil means written.
    static func writePrivateFile(_ data: Data, to url: URL) -> String? {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
        guard written == data.count else { unlink(url.path); return "short write" }
        return nil
    }

    /// Deletes regular files in `dir` last changed more than `age` seconds ago. attributesOfItem
    /// reads the entry itself (lstat), so symlinks and directories are skipped, never followed.
    static func sweepStale(in dir: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names {
            let p = dir.appendingPathComponent(name).path
            guard let a = try? fm.attributesOfItem(atPath: p), a[.type] as? FileAttributeType == .typeRegular,
                  let m = a[.modificationDate] as? Date, m < cutoff else { continue }
            // unlink, not removeItem: if the entry was swapped for a directory after the check,
            // unlink fails instead of deleting a tree, and a symlink is removed, never followed.
            unlink(p)
        }
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

    /// Mask runs sweep the default folder of copies older than this before writing a new one
    /// (CS-18): an hour covers the five-minute allow window several times over, and keeps
    /// $TMPDIR/cheapshot-masked from filling with copies no entry will ever use again.
    static let maskSweepAge: TimeInterval = 3600

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
        // CS-18: the default folder's stale copies go before a new one lands. Only that folder
        // is ever swept; an explicit --out directory is the caller's, and is left alone.
        // ensurePrivateDir first: a symlink planted at $TMPDIR/cheapshot-masked (or a folder
        // another user owns) is refused, so the sweep can never list and delete files elsewhere.
        let dir = dest.deletingLastPathComponent()
        if out == nil {
            // ensurePrivateDir makes only the last folder; a missing $TMPDIR is created first, as
            // the old createDirectory(withIntermediateDirectories:) call did.
            try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let why = ensurePrivateDir(dir) { return fail(why) }
            sweepStale(in: dir, olderThan: maskSweepAge)
        }
        let digest: String
        do {
            if out != nil {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let png = try Masker.pngData(result.image)
            // writePrivateFile: mode 0600, O_EXCL refuses an existing file (the source, or
            // anything already at --out) and O_NOFOLLOW a symlink, so nothing is overwritten.
            if let why = writePrivateFile(png, to: dest) {
                return fail("cannot write \(dest.path): \(why)")
            }
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
        let read = Pipeline.readText(raw, redaction: redaction(redactor))
        let (text, report, tt) = (read.text, read.report, read.textTokens)
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

    static func runImages(_ opts: Options, paths: [String], redactor: Redactor?, io: CLIIO) -> Int32 {
        // Only the PDF branch reads --pages; on any other input it was accepted and ignored.
        if opts.pages != nil, let f = paths.first(where: { ($0 as NSString).pathExtension.lowercased() != "pdf" }) {
            io.err("cheapshot: --pages applies to PDF input only, not \(f)\ntry: cheapshot --help\n")
            return 2
        }
        var results: [[String: Any]] = []
        // PDFs and images are counted apart: see Pipeline.Totals.
        var pdfs = Pipeline.Totals(), images = Pipeline.Totals()
        var failed = 0

        for f in paths {
            guard FileManager.default.fileExists(atPath: f) else {
                failed += 1
                results.append(["file": f, "error": "no such file"])
                io.err("cheapshot: no such file \(f)\n")
                continue
            }
            if (f as NSString).pathExtension.lowercased() == "pdf" {
                let read: Pipeline.PDFRead
                do { read = try Pipeline.readPDF(url: URL(fileURLWithPath: f), pages: opts.pages, minConfidence: opts.minConfidence,
                                                 forceOCR: opts.forceOCR, redaction: redaction(redactor)) }
                catch {
                    failed += 1
                    results.append(["file": f, "error": "\(error)"])
                    io.err("cheapshot: \(error)\n")
                    continue
                }
                let doc = read.document   // page lines already redacted
                pdfs.add(imageTokens: read.imageTokens, textTokens: read.textTokens, redactions: read.report.total)
                results.append(["file": f, "text": read.text, "redactions": read.report.counts,
                                "image_tokens": read.imageTokens, "text_tokens": read.textTokens,
                                "source": ["path": doc.path, "sha256": doc.sha256, "pages": doc.pageCount],
                                "pages": doc.pages.map { ["n": $0.n, "lane": $0.lane.rawValue,
                                                          "width": $0.width, "height": $0.height,
                                                          "lines": lineJSON(alreadyRedacted: $0.lines)] as [String: Any] }])
                if !opts.json {
                    if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                    io.out(read.text + "\n")
                }
                continue
            }
            let read: Pipeline.ImageRead
            do { read = try Pipeline.readImage(path: f, redaction: redaction(redactor), minConfidence: opts.minConfidence) }
            catch Pipeline.ReadError.unreadableImage {
                failed += 1
                results.append(["file": f, "error": "\(Pipeline.ReadError.unreadableImage)"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            } catch {
                // OCR failed. Its message is printed as is, after the file name.
                failed += 1
                results.append(["file": f, "error": "\(error)"])
                io.err("cheapshot: \(f): \(error)\n")
                continue
            }
            if read.retried && read.status == .empty {
                io.err("cheapshot: \(f): no text found after a retry, though it looks like a screenshot\n")
            }
            images.add(imageTokens: read.imageTokens, textTokens: read.textTokens, redactions: read.report.total)
            results.append(["file": f, "text": read.text, "redactions": read.report.counts,
                            "image_tokens": read.imageTokens, "text_tokens": read.textTokens,
                            "lines": lineJSON(alreadyRedacted: read.lines),   // lines already redacted
                            // "empty" with "retried": true is a screenshot-like image that still read blank
                            // (a likely cold-start OCR failure); "empty" without a retry is a photo or a
                            // small image. Callers must not treat the first like the second.
                            "ocr_status": read.status.rawValue, "retried": read.retried,
                            "screenshot_like": read.screenshotLike])
            if !opts.json {
                if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                io.out(read.text + "\n")
            }
        }

        let totalImage = pdfs.imageTokens + images.imageTokens
        let totalText = pdfs.textTokens + images.textTokens
        if opts.json, !emit(payload(results, imageTokens: totalImage, textTokens: totalText), io) { return 1 }
        let ok = paths.count - failed
        // One line per kind present, so a PDF run never reports itself as measured image savings.
        for entry in Pipeline.ledgerEntries(pdfs: pdfs, images: images, redacted: opts.redact) { record(entry, opts, io) }
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
