// Swift. The read pipeline: image, PDF or text in; redacted text, redaction counts, token counts
// and ledger lines out. The CLI and the native app both call this, so the same input and the
// same rules give the same answer in both (native app plan, step 2: moved here unchanged from
// Sources/CheapshotCLI/Runner.swift at 1c0876a, v0.6.0; PipelineParityTests in the CLI tests prove the
// CLI's output did not change).
//
// Nothing here prints, exits or decides an output format. Callers do that: the CLI turns these
// results into its text or --json output, the app into a window.
import Foundation
import CoreGraphics

public enum Pipeline {

    // MARK: - which rules apply

    /// The rules file a run uses, and whether someone named it on purpose.
    public struct RulesSource: Equatable {
        public let url: URL
        /// True for a file passed explicitly (--rules) or through $CHEAPSHOT_RULES. A named file
        /// that is missing or broken is an error; the default file is not (see ``redactor(rules:warn:)``).
        public let named: Bool
        public init(url: URL, named: Bool) { self.url = url; self.named = named }
    }

    /// First match wins: `explicitPath`, then $CHEAPSHOT_RULES, then rules.json next to the
    /// ledger when that file exists. nil means built-in rules only.
    public static func rulesSource(explicitPath: String?, environment: [String: String], home: String) -> RulesSource? {
        if let p = explicitPath { return RulesSource(url: URL(fileURLWithPath: p), named: true) }
        if let p = environment["CHEAPSHOT_RULES"], !p.isEmpty { return RulesSource(url: URL(fileURLWithPath: p), named: true) }
        let fallback = Ledger.resolveURL(environment: environment, home: home)
            .deletingLastPathComponent().appendingPathComponent("rules.json")
        return FileManager.default.fileExists(atPath: fallback.path) ? RulesSource(url: fallback, named: false) : nil
    }

    /// Every built-in rule, plus the custom rules in `rules` placed first so they win. The file's
    /// `preset` and `disabled` list are ignored here (``RuleTogglePolicy/allRules``), so this
    /// entry point keeps its pre-v2 meaning and never returns a weakened redactor without a mark.
    /// A caller that honours switches uses ``ruleSelection(rules:presetOverride:policy:warn:)``
    /// and shows the marks itself.
    ///
    /// A named file that cannot be read or parsed throws. The default file failing does not: it
    /// calls `warn` and keeps the built-in rules, because failing every run would let the Read
    /// hook pass raw pixels through (a typo, or the app writing the file at that moment).
    public static func redactor(rules: RulesSource?, warn: (String) -> Void) throws -> Redactor {
        Redactor(selection: try ruleSelection(rules: rules, policy: .allRules, warn: warn))
    }

    /// The rules a run uses (rules file v2, NOV-156): the file's custom rules first, then the
    /// built-ins its preset and `disabled` list leave on, after `presetOverride` (--preset) and
    /// `policy` (``RuleTogglePolicy``) are applied.
    ///
    /// Failure direction is always toward more redaction. A named file is read strictly: a
    /// missing or broken file, a version above 2, an unknown preset or rule name all throw. The
    /// default file is read leniently: one that cannot be read or parsed calls `warn` and runs
    /// every built-in rule; an unknown preset or rule name inside it warns and is ignored. An
    /// unknown `presetOverride` throws either way.
    public static func ruleSelection(rules: RulesSource?, presetOverride: String? = nil,
                                     policy: RuleTogglePolicy = .honour,
                                     warn: (String) -> Void) throws -> RuleSelection {
        var contents: RuleFileContents? = nil
        if let rules = rules {
            if rules.named {
                contents = try RuleFile.loadContents(rules.url, strict: true, warn: warn)
            } else {
                do {
                    contents = try RuleFile.loadContents(rules.url, strict: false) { warn("\(rules.url.path): \($0)") }
                } catch {
                    warn("ignoring \(rules.url.path): \(error); using built-in rules only")
                }
            }
        }
        return try RuleSelection.resolve(contents, presetOverride: presetOverride, policy: policy)
    }

    // MARK: - redaction

    /// Whether a read redacts, said out loud. Redaction off is `.raw` by name, never a missing
    /// redactor, so an app cannot turn redaction off by accident (Fable review of step 2, row 3).
    public enum Redaction {
        /// Redact with these rules. The normal case.
        case redact(Redactor)
        /// Leave the text exactly as read: the CLI's --raw. Every result says `redacted: false`.
        case raw

        public var isRedacting: Bool {
            if case .redact = self { return true }
            return false
        }
    }

    /// `text` redacted, or unchanged with an empty report for `.raw`.
    public static func redact(_ text: String, with redaction: Redaction) -> (text: String, report: RedactionReport) {
        switch redaction {
        case .redact(let redactor): return redactor.redact(text)
        case .raw: return (text, RedactionReport())
        }
    }

    /// The same lines with their text redacted; number, box, confidence and fence unchanged.
    ///
    /// The lines are redacted joined, exactly as the document text is, and split back apart, so
    /// the lines carry the same redaction as the text. Redacting each line on its own was weaker:
    /// a rule whose pattern crosses a newline redacted the document but not the lines. When a rule
    /// does eat a newline the split no longer lines up, and then per-line redaction is the honest
    /// fallback: keeping each line's number and box on the right text matters more.
    public static func redactLines(_ lines: [RenderedLine], with redaction: Redaction) -> [RenderedLine] {
        let joined = redact(lines.map(\.text).joined(separator: "\n"), with: redaction).text.components(separatedBy: "\n")
        let texts = joined.count == lines.count ? joined : lines.map { redact($0.text, with: redaction).text }
        return zip(lines, texts).map { l, text in
            var out = l
            out.text = text
            return out
        }
    }

    // MARK: - text

    public struct TextRead {
        public var text: String
        public var report: RedactionReport
        public var textTokens: Int
        /// False only for a `.raw` read: then `text` is exactly what was read.
        public var redacted: Bool
    }

    /// Redacts plain text. One trailing newline is dropped first, so text read from a file or a
    /// pipe ends where its last line ends.
    public static func readText(_ raw: String, redaction: Redaction) -> TextRead {
        let input = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let (text, report) = redact(input, with: redaction)
        return TextRead(text: text, report: report, textTokens: Tokens.text(text), redacted: redaction.isRedacting)
    }

    // MARK: - images

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        /// The file or bytes are not an image ImageLoader can decode.
        case unreadableImage
        public var description: String {
            switch self { case .unreadableImage: return "cannot read image" }
        }
    }

    public struct ImageRead {
        /// The recognized text, laid out (columns, fences for monospaced runs) and redacted.
        public var text: String
        public var report: RedactionReport
        /// One entry per recognized line, with its text redacted the same way as ``text``.
        /// Boxes are in pixels with a top-left origin.
        public var lines: [RenderedLine]
        /// The pixel size the token cost is based on.
        public var width: Int
        public var height: Int
        /// What the image would cost an agent to look at, and what the text costs instead.
        public var imageTokens: Int
        public var textTokens: Int
        /// False only for a `.raw` read: then `text` and `lines` are exactly what OCR read.
        public var redacted: Bool
        /// The cold-start check (v0.6.0, OCR.recognizeLayoutChecked): `retried` is true when a
        /// second OCR pass ran; `screenshotLike` is the image heuristic the retry was gated on.
        /// `status` `.empty` with `retried` is a screenshot-like image that still read blank, a
        /// likely OCR failure, not a photo. Callers must not treat the two alike.
        public var retried: Bool
        public var screenshotLike: Bool
        public var status: OCR.Status { lines.isEmpty ? .empty : .ok }
    }

    /// Reads an image file: decode upright, OCR with layout (one in-process retry on a cold start),
    /// redact, count.
    /// Throws ``ReadError/unreadableImage`` when the file cannot be decoded, and passes OCR
    /// errors through unchanged.
    public static func readImage(path: String, redaction: Redaction, minConfidence: Float) throws -> ImageRead {
        guard let image = ImageLoader.load(path: path) else { throw ReadError.unreadableImage }
        return try readImage(image, pixelSize: ImageLoader.pixelSize(path: path), redaction: redaction, minConfidence: minConfidence)
    }

    /// Reads an image held in memory (a paste or a drop), so its pixels never touch disk.
    public static func readImage(data: Data, redaction: Redaction, minConfidence: Float) throws -> ImageRead {
        guard let image = ImageLoader.load(data: data) else { throw ReadError.unreadableImage }
        return try readImage(image, pixelSize: ImageLoader.pixelSize(data: data), redaction: redaction, minConfidence: minConfidence)
    }

    /// Reads decoded pixels. `pixelSize` is the size to bill tokens for; it defaults to the
    /// image's own size, and differs only for a file whose reader reports another size (an SVG).
    public static func readImage(_ image: CGImage, pixelSize: (width: Int, height: Int)? = nil,
                                 redaction: Redaction, minConfidence: Float) throws -> ImageRead {
        let checked = try OCR.recognizeLayoutChecked(image: image, minConfidence: minConfidence)
        let rendered = checked.lines
        let (text, report) = redact(Layout.text(rendered), with: redaction)
        let size = pixelSize ?? (image.width, image.height)
        return ImageRead(text: text, report: report, lines: redactLines(rendered, with: redaction),
                         width: size.width, height: size.height,
                         imageTokens: Tokens.image(width: size.width, height: size.height),
                         textTokens: Tokens.text(text), redacted: redaction.isRedacting,
                         retried: checked.retried, screenshotLike: checked.screenshotLike)
    }

    // MARK: - PDFs

    public struct PDFRead {
        /// The document as PDFSource read it, with every page's lines redacted like ``text``.
        public var document: PDFDocumentResult
        /// All pages' text, with page markers, redacted.
        public var text: String
        public var report: RedactionReport
        /// What reading every page as a 2x image would have cost: an estimate, not a measurement.
        public var imageTokens: Int
        public var textTokens: Int
        /// False only for a `.raw` read: then `text` and every page's lines are exactly as read.
        public var redacted: Bool
    }

    /// Reads a PDF (text lane or scan lane per page), redacts, counts. PDFSource errors pass
    /// through unchanged.
    public static func readPDF(url: URL, pages: ClosedRange<Int>?, minConfidence: Float, forceOCR: Bool,
                               redaction: Redaction) throws -> PDFRead {
        var doc = try PDFSource.pages(of: url, range: pages, minConfidence: minConfidence, forceOCR: forceOCR)
        let (text, report) = redact(PDFSource.text(of: doc), with: redaction)
        let it = doc.pages.reduce(0) { $0 + Tokens.image(width: $1.width, height: $1.height) }
        for i in doc.pages.indices { doc.pages[i].lines = redactLines(doc.pages[i].lines, with: redaction) }
        return PDFRead(document: doc, text: text, report: report, imageTokens: it, textTokens: Tokens.text(text),
                       redacted: redaction.isRedacting)
    }

    // MARK: - totals and the ledger

    /// One kind of input's running totals. PDFs and images are counted apart because they mean
    /// different things in the ledger: an image line is a measured saving, a PDF line is an
    /// estimate of what reading the pages as images would have cost.
    public struct Totals: Equatable {
        public var inputs = 0, imageTokens = 0, textTokens = 0, redactions = 0
        public init(inputs: Int = 0, imageTokens: Int = 0, textTokens: Int = 0, redactions: Int = 0) {
            self.inputs = inputs; self.imageTokens = imageTokens; self.textTokens = textTokens; self.redactions = redactions
        }
        public mutating func add(imageTokens it: Int, textTokens tt: Int, redactions r: Int) {
            inputs += 1; imageTokens += it; textTokens += tt; redactions += r
        }
    }

    /// The ledger lines for a run: one per kind present, "pdf" before "image", so a PDF run never
    /// reports itself as measured image savings. Empty when nothing was read.
    public static func ledgerEntries(pdfs: Totals, images: Totals, redacted: Bool) -> [LedgerEntry] {
        [("pdf", pdfs), ("image", images)].filter { $0.1.inputs > 0 }.map { mode, t in
            ledgerEntry(LedgerEntry(mode: mode, inputs: t.inputs, imageTokens: t.imageTokens,
                                    textTokens: t.textTokens, redactions: t.redactions), redacted: redacted)
        }
    }

    /// `entry` marked raw when redaction was off, so a raw run is visible in the ledger.
    public static func ledgerEntry(_ entry: LedgerEntry, redacted: Bool) -> LedgerEntry {
        var entry = entry
        if !redacted { entry.raw = true }
        return entry
    }

    /// Tokens not spent by reading text instead of the image, floored at zero, and that as a
    /// truncated percent of the image cost. Zero image tokens is zero saved, not a division.
    public static func savings(imageTokens: Int, textTokens: Int) -> (saved: Int, pct: Int) {
        let saved = max(0, imageTokens - textTokens)
        let pct = imageTokens > 0 ? Int(Double(saved) / Double(imageTokens) * 100) : 0
        return (saved, pct)
    }
}
