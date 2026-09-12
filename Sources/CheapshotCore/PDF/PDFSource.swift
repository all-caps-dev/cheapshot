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
/// for free. Scan lane: when the text layer has under 20 characters, render at 2x and run the
/// same Vision path as screenshots.
public enum PDFSource {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static let scanLaneThreshold = 20
    public static let renderScale: CGFloat = 2

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func pages(of url: URL, range: ClosedRange<Int>?, minConfidence: Float) throws -> PDFDocumentResult {
        guard let doc = PDFDocument(url: url) else { throw Failure(message: "cannot open PDF \(url.path)") }
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
            pages.append(try process(page, n: n, minConfidence: minConfidence))
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

    static func process(_ page: PDFPage, n: Int, minConfidence: Float) throws -> PDFPageResult {
        let (w, h) = pixelSize(page)
        let string = page.string ?? ""
        if string.filter({ !$0.isWhitespace }).count >= scanLaneThreshold {
            let bounds = page.bounds(for: .mediaBox)
            return PDFPageResult(n: n, lane: .text, lines: textLines(page, string: string, bounds: bounds), width: w, height: h)
        }
        let image = try render(page, width: w, height: h)
        let lines = try OCR.recognizeLayout(image: image, minConfidence: minConfidence)
        return PDFPageResult(n: n, lane: .scan, lines: lines, width: w, height: h)
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
