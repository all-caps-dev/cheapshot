import Foundation
import Vision
import CoreGraphics

public enum OCR {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Vision text recognition on one image. Boxes come back in pixels with a top-left origin.
    public static func recognize(image: CGImage, minConfidence: Float, languageCorrection: Bool = true) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        let lines = try perform(request, on: image, minConfidence: minConfidence, roi: nil)
        return OCRResult(lines: lines, width: image.width, height: image.height)
    }

    /// Full screenshot pipeline: recognize with correction on, find monospace runs, recognize each
    /// run's region again with correction off (so hashes and tokens are not "corrected" into words),
    /// then lay out with indentation and fences.
    public static func recognizeLayout(image: CGImage, minConfidence: Float) throws -> [RenderedLine] {
        let first = try recognize(image: image, minConfidence: minConfidence)
        var lines = Layout.sorted(first.lines)
        // Detected once, on the first pass, and then used verbatim for the render. Re-detecting
        // after the replacement would judge different strings: the uncorrected text has different
        // character counts, so a region that was worth re-OCR'ing could come back unfenced.
        let runs = Layout.monospaceRuns(lines)
        for run in runs.reversed() {                             // reversed so earlier indices stay valid
            let union = run.reduce(CGRect.null) { $0.union(lines[$1].bbox) }
            let pad: CGFloat = 4
            let region = union.insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !region.isEmpty else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.regionOfInterest = normalized(region, width: image.width, height: image.height)
            // Only a line-for-line replacement is safe to take. The confidence floor, the pad, and
            // Vision merging or splitting rows inside a crop can all return fewer lines than the
            // run had, and swapping that in would silently drop text from the output and the
            // ledger. A short replacement falls back to the corrected first-pass lines, which stay
            // fenced, and keeps every run range valid for the render below.
            guard let replacement = try? perform(request, on: image, minConfidence: minConfidence, roi: request.regionOfInterest),
                  replacement.count == run.count else { continue }
            lines.replaceSubrange(run, with: Layout.sorted(replacement))
        }
        return Layout.render(lines, runs: runs)
    }

    static func perform(_ request: VNRecognizeTextRequest, on image: CGImage, minConfidence: Float, roi: CGRect?) throws -> [OCRLine] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw Failure(message: "vision: \(error.localizedDescription)") }
        var lines: [OCRLine] = []
        for o in request.results ?? [] {
            guard let top = o.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            // With a regionOfInterest, Vision reports boxes relative to that region.
            var box = o.boundingBox
            if let roi = roi {
                box = CGRect(x: roi.minX + box.minX * roi.width, y: roi.minY + box.minY * roi.height,
                             width: box.width * roi.width, height: box.height * roi.height)
            }
            // The layout arithmetic quantizes rows with Int(minY / pitch), which traps on a
            // non-finite value. Vision never gets to feed one in.
            let bbox = pixels(box, width: image.width, height: image.height)
            guard bbox.origin.x.isFinite, bbox.origin.y.isFinite, bbox.width.isFinite, bbox.height.isFinite else { continue }
            let cells = wordCells(top, lineWidth: bbox.width, roi: roi, width: image.width, height: image.height)
            lines.append(OCRLine(text: top.string, bbox: bbox, confidence: top.confidence,
                                 cellWidth: cells?.width, cellVariation: cells?.variation))
        }
        return lines
    }

    /// The per-character cell width measured from Vision's word boxes, and how much those words
    /// disagree. `boundingBox(for:)` resolves at word granularity, which is the only estimate
    /// that separates a fixed-width font from prose: the whole-line width over the string length
    /// is skewed by inserted spaces, corrected tokens and ink-fit boxes, and lands in the same
    /// range for both. Words under 3 characters are too short for the division to mean anything,
    /// and a box wider than 90% of the line is Vision handing back the line box for a range it
    /// could not resolve. Fewer than three usable words is no evidence at all.
    static func wordCells(_ top: VNRecognizedText, lineWidth: CGFloat, roi: CGRect?,
                          width: Int, height: Int) -> (width: CGFloat, variation: CGFloat)? {
        let s = top.string
        var cells: [CGFloat] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard !s[i].isWhitespace else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
            defer { i = j }
            let n = s.distance(from: i, to: j)
            guard n >= 3, let word = try? top.boundingBox(for: i..<j) else { continue }
            var box = word.boundingBox
            if let roi = roi {
                box = CGRect(x: roi.minX + box.minX * roi.width, y: roi.minY + box.minY * roi.height,
                             width: box.width * roi.width, height: box.height * roi.height)
            }
            let w = box.width * CGFloat(width)
            guard w.isFinite, w > 0, w <= 0.9 * lineWidth else { continue }
            cells.append(w / CGFloat(n))
        }
        guard cells.count >= 3 else { return nil }
        let mean = cells.reduce(0, +) / CGFloat(cells.count)
        guard mean > 0 else { return nil }
        let variance = cells.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(cells.count)
        return (Layout.median(cells), variance.squareRoot() / mean)
    }

    /// Vision: normalized, bottom-left origin. Ours: pixels, top-left origin.
    static func pixels(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
    }

    static func normalized(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: r.minX / w, y: (h - r.maxY) / h, width: r.width / w, height: r.height / h)
    }
}
