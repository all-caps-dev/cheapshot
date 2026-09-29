import Foundation
import PDFKit
import CryptoKit
import CoreGraphics
import AppKit

public enum PDFLane: String, Codable { case text, scan }

public struct PDFPageResult {
    public var n: Int
    public var lane: PDFLane
    public var lines: [RenderedLine]
    public var width: Int      // rendered pixel size at 2x, what an agent would pay for
    public var height: Int
}

public struct PDFDocumentResult {
    public var path: String
    public var sha256: String
    public var pageCount: Int
    public var pages: [PDFPageResult]
}

/// Two lanes per page. Text lane: PDFKit's text layer, with fonts, so fixed-pitch fonts fence
/// for free. Scan lane: render at 2x and run the same Vision path as screenshots.
///
/// Every page is rendered and OCR'd, and the text layer is kept only when it accounts for what
/// the page shows. Having a layer was not enough: an OCR'd scan can carry a layer of `! " % &`
/// or one that silently leaves lines out, and both used to come out as the page's text. A page
/// takes the scan lane when its layer has under 20 non-whitespace characters, when any OCR line
/// is one the layer lacks (`layerMisses`), or when the caller forces OCR. The OCR is the same
/// pass the scan lane returns, so a page that falls back is not read twice.
public enum PDFSource {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static let scanLaneThreshold = 20
    public static let renderScale: CGFloat = 2
    /// An OCR line is judged only when it has at least this many word pairs (four words), so a
    /// heading, a page number, a code line or a table cell never counts against the layer.
    public static let minimumLinePairs = 3
    /// An OCR line is missing from the layer when more than this share of its word pairs are.
    /// Measured on the four papers reported 2026-09-29 with Vision's accurate pass: every line
    /// of the good control scored 0.4 or less (all but one scored 0), and the lines a layer had
    /// really dropped scored 0.7 to 1.0. Word pairs, not single words, because the common words
    /// of a dropped line ("the", "that", "with") are nearly always elsewhere on the page.
    public static let missingLineShare = 0.5

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `forceOCR` sends every page to the scan lane, text layer or not.
    public static func pages(of url: URL, range: ClosedRange<Int>?, minConfidence: Float,
                             forceOCR: Bool = false) throws -> PDFDocumentResult {
        guard let doc = PDFDocument(url: url) else { throw Failure(message: "cannot open PDF \(url.path)") }
        // A locked document still opens, still reports its page count, and still hands back pages
        // whose `string` is nil and whose render is blank. Left alone it sails through the scan
        // lane and reports a saving on text nobody read.
        guard !doc.isLocked else { throw Failure(message: "\(url.lastPathComponent) is password-protected") }
        let count = doc.pageCount
        guard count > 0 else { throw Failure(message: "\(url.path) has no pages") }
        let r = range ?? 1...count
        guard r.lowerBound >= 1, r.upperBound <= count else {
            throw Failure(message: "--pages \(r.lowerBound)-\(r.upperBound) is outside 1-\(count) for \(url.lastPathComponent)")
        }
        var pages: [PDFPageResult] = []
        for n in r {
            guard let page = doc.page(at: n - 1) else {
                throw Failure(message: "cannot read page \(n) of \(url.lastPathComponent)")
            }
            pages.append(try process(page, n: n, minConfidence: minConfidence, forceOCR: forceOCR))
        }
        return PDFDocumentResult(path: url.path, sha256: try sha256(of: url), pageCount: count, pages: pages)
    }

    /// Plain payload with page separators.
    public static func text(of result: PDFDocumentResult) -> String {
        result.pages.map { "--- page \($0.n) ---\n" + Layout.text($0.lines) }.joined(separator: "\n\n")
    }

    /// The page's size in rendered pixels at `renderScale`. `bounds(for:)` reports the media box
    /// as written, ignoring `/Rotate`, but `draw(with:to:)` applies the rotation, so a quarter-turn
    /// page draws landscape into a portrait bitmap and comes back blank. Swap the axes here and the
    /// bitmap matches what is drawn into it.
    static func pixelSize(_ page: PDFPage) -> (width: Int, height: Int) {
        let bounds = page.bounds(for: .mediaBox)
        let quarterTurned = (((page.rotation % 360) + 360) % 360) % 180 == 90
        let w = quarterTurned ? bounds.height : bounds.width
        let h = quarterTurned ? bounds.width : bounds.height
        return (Int((w * renderScale).rounded()), Int((h * renderScale).rounded()))
    }

    static func process(_ page: PDFPage, n: Int, minConfidence: Float, forceOCR: Bool = false) throws -> PDFPageResult {
        let (w, h) = pixelSize(page)
        let string = page.string ?? ""
        let image = try render(page, width: w, height: h)
        let lines = try OCR.recognizeLayout(image: image, minConfidence: minConfidence)
        if !forceOCR, string.filter({ !$0.isWhitespace }).count >= scanLaneThreshold,
           layerMisses(layer: string, ocrLines: lines.map(\.text)) == 0 {
            let bounds = page.bounds(for: .mediaBox)
            return PDFPageResult(n: n, lane: .text, lines: textLines(page, string: string, bounds: bounds), width: w, height: h)
        }
        return PDFPageResult(n: n, lane: .scan, lines: lines, width: w, height: h)
    }

    /// How many OCR lines the text layer does not account for. A line counts when it has at
    /// least `minimumLinePairs` word pairs and more than `missingLineShare` of them appear
    /// nowhere in the layer. Pairs are compared within a line only, so the layer's line order
    /// (two columns, reading order) does not matter, and one misread word costs at most two
    /// pairs, which a line of ordinary length absorbs.
    static func layerMisses(layer: String, ocrLines: [String]) -> Int {
        let known = Set(wordPairs(layer.split(whereSeparator: \.isNewline).flatMap { words(String($0)) }))
        return ocrLines.filter { line in
            let pairs = wordPairs(words(line))
            guard pairs.count >= minimumLinePairs else { return false }
            let missing = pairs.filter { !known.contains($0) }.count
            return Double(missing) / Double(pairs.count) > missingLineShare
        }.count
    }

    /// The word-like tokens of one line, normalised so the layer and OCR spell a word the same
    /// way: compatibility-decomposed (so a "ﬁ" ligature is "fi" and an accent drops away),
    /// lowercased, letters only. A token is word-like when it has two or more letters and letters
    /// are at least half of it, so `! " % &` and bare numbers contribute nothing.
    static func words(_ line: String) -> [String] {
        line.decomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                let letters = token.filter(\.isLetter)
                return letters.count >= 2 && letters.count * 2 >= token.count ? String(letters) : nil
            }
    }

    static func wordPairs(_ words: [String]) -> [String] {
        words.count < 2 ? [] : (1..<words.count).map { words[$0 - 1] + " " + words[$0] }
    }

    /// One RenderedLine per non-blank line of the text layer, with its selection bounds
    /// converted to a top-left origin and `fenced` set when the first glyph's font is fixed pitch.
    ///
    /// The fonts come from one attributed string for the whole page rather than one per line:
    /// PDFKit logs a diagnostic to stderr for every attributed string it builds, so building one
    /// per line made the noise scale with the page. Its index space is only used when its length
    /// agrees with `page.string`; otherwise no line is fenced, which is the safe direction.
    static func textLines(_ page: PDFPage, string: String, bounds: CGRect) -> [RenderedLine] {
        var out: [RenderedLine] = []
        var location = 0
        let attributed = page.attributedString
        let fontsAreAddressable = attributed?.length == (string as NSString).length
        for raw in string.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = (String(raw) as NSString).length
            let range = NSRange(location: location, length: length)
            location += length + 1
            let text = String(raw).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var bbox = CGRect.zero
            var mono = false
            if let sel = page.selection(for: range) {
                let b = sel.bounds(for: page)
                bbox = CGRect(x: b.minX - bounds.minX, y: bounds.maxY - b.maxY, width: b.width, height: b.height)
            }
            if fontsAreAddressable, let attr = attributed, range.length > 0, range.location < attr.length,
               let font = attr.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                mono = font.isFixedPitch
            }
            out.append(RenderedLine(n: out.count + 1, text: text, bbox: bbox, confidence: 1.0, fenced: mono))
        }
        return out
    }

    /// The page on a white bitmap at `renderScale`. `draw(with:to:)` maps the media box onto the
    /// current transform itself, origin and rotation included, so the only transform this adds is
    /// the scale; translating by the box origin as well would shift a non-zero-origin page twice.
    static func render(_ page: PDFPage, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "cannot allocate a \(width)x\(height) bitmap")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw Failure(message: "cannot render page") }
        return image
    }
}
