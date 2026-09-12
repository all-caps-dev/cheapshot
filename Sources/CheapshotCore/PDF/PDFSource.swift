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
            guard let page = doc.page(at: n - 1) else { continue }
            pages.append(try process(page, n: n, minConfidence: minConfidence))
        }
        return PDFDocumentResult(path: url.path, sha256: try sha256(of: url), pageCount: count, pages: pages)
    }

    /// Plain payload with page separators.
    public static func text(of result: PDFDocumentResult) -> String {
        result.pages.map { "--- page \($0.n) ---\n" + Layout.text($0.lines) }.joined(separator: "\n\n")
    }

    static func process(_ page: PDFPage, n: Int, minConfidence: Float) throws -> PDFPageResult {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int((bounds.width * renderScale).rounded()), h = Int((bounds.height * renderScale).rounded())
        let string = page.string ?? ""
        if string.filter({ !$0.isWhitespace }).count >= scanLaneThreshold {
            return PDFPageResult(n: n, lane: .text, lines: textLines(page, string: string, bounds: bounds), width: w, height: h)
        }
        let image = try render(page, bounds: bounds, width: w, height: h)
        let lines = try OCR.recognizeLayout(image: image, minConfidence: minConfidence)
        return PDFPageResult(n: n, lane: .scan, lines: lines, width: w, height: h)
    }

    /// One RenderedLine per non-blank line of the text layer, with its selection bounds
    /// converted to a top-left origin and `fenced` set when the first glyph's font is fixed pitch.
    static func textLines(_ page: PDFPage, string: String, bounds: CGRect) -> [RenderedLine] {
        var out: [RenderedLine] = []
        var location = 0
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
                if let attr = sel.attributedString, attr.length > 0,
                   let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    mono = font.isFixedPitch
                }
            }
            out.append(RenderedLine(n: out.count + 1, text: text, bbox: bbox, confidence: 1.0, fenced: mono))
        }
        return out
    }

    static func render(_ page: PDFPage, bounds: CGRect, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "cannot allocate a \(width)x\(height) bitmap")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: renderScale, y: renderScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw Failure(message: "cannot render page") }
        return image
    }
}
