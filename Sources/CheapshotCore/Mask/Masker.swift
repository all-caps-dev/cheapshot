// Swift. `cheapshot mask`: a copy of a screenshot with opaque black boxes over every line whose
// text a redaction rule changed, and over every line Vision was unsure of (NOV-95).
//
// Why: the Read hook keeps raw pixels away from the model because the pixels would show the very
// secret the text redaction hid. A masked copy keeps the layout (what is where, colours, icons)
// and paints over the risky lines, so an agent can look at it without a person approving raw access.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Why a box was painted.
public enum MaskReason: String, Equatable {
    case redacted       // a redaction rule changed this line's text
    case lowConfidence  // Vision's confidence was under the floor, so the text check cannot be trusted
}

public struct MaskBox: Equatable {
    /// Pixels, top-left origin, before padding. Same space as the `bbox` in `cheapshot --json`.
    public var rect: CGRect
    public var reason: MaskReason
    public init(rect: CGRect, reason: MaskReason) { self.rect = rect; self.reason = reason }
}

public struct MaskResult {
    public var image: CGImage
    public var boxes: [MaskBox]
    /// The redaction counts of the original image, as `cheapshot --json` would report them.
    public var report: RedactionReport
    /// How many OCR rounds it took until a re-read of the masked copy found nothing new to cover.
    public var rounds: Int
}

public enum Masker {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Give up after this many rounds of "mask, re-read the masked copy, mask what it still finds".
    public static let maxRounds = 3

    /// Loads the image straight from the file with ImageIO, so the CGImage is exactly the file's
    /// pixel grid. Running OCR on this same CGImage keeps the boxes and the painting in one pixel
    /// space, whatever DPI the file claims (a @2x screenshot is 144 DPI; NSImage would size it in
    /// points). An EXIF rotation is refused: Vision would read the unrotated pixels and miss text.
    public static func loadPixels(path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure(message: "cannot read image \(path)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let o = props?[kCGImagePropertyOrientation] as? NSNumber, o.intValue != 1 {
            throw Failure(message: "\(path) has an EXIF rotation (\(o.intValue)); mask supports unrotated images only")
        }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Failure(message: "cannot decode image \(path)")
        }
        return image
    }

    /// Every line any of three OCR passes finds risky. Each pass sees the text differently: the
    /// layout pass (what the hook shows), plain recognition with language correction, and without
    /// it (correction can turn a token into words a rule no longer matches). Taking all three
    /// catches more secrets than any one. The confidence floor is applied here, not in Vision,
    /// so the lines under it come back with their boxes and get painted.
    public static func findBoxes(in image: CGImage, redactor: Redactor, minConfidence: Float) throws -> [MaskBox] {
        let layout = try OCR.recognizeLayout(image: image, minConfidence: 0)
        var boxes = flag(layout.map { ($0.text, $0.bbox, $0.confidence) }, redactor: redactor, minConfidence: minConfidence)
        for correction in [true, false] {
            let r = try OCR.recognize(image: image, minConfidence: 0, languageCorrection: correction)
            let lines = Layout.sorted(r.lines).map { ($0.text, $0.bbox, $0.confidence) }
            boxes += flag(lines, redactor: redactor, minConfidence: minConfidence)
        }
        return dedupe(boxes)
    }

    /// The pure half of `findBoxes`: which lines to paint, given their text, box and confidence
    /// in reading order. A line is redacted when a rule changes it on its own, or as part of the
    /// whole page, or together with the line after it (a rule whose pattern spans a newline).
    static func flag(_ lines: [(text: String, bbox: CGRect, confidence: Float)], redactor: Redactor,
                     minConfidence: Float) -> [MaskBox] {
        let texts = lines.map(\.text)
        let single = texts.map { redactor.redact($0).text }
        var hit = zip(texts, single).map { $0 != $1 }
        // The whole page at once, when the redacted page still splits into the same lines.
        let joined = redactor.redact(texts.joined(separator: "\n")).text.components(separatedBy: "\n")
        if joined.count == texts.count {
            for i in texts.indices where joined[i] != texts[i] { hit[i] = true }
        }
        // Each pair of neighbours: if the pair redacts differently from its two halves, a rule
        // matched across the line break, so both lines hold part of the secret.
        if texts.count >= 2 {
            for i in 0..<(texts.count - 1) {
                let pair = redactor.redact(texts[i] + "\n" + texts[i + 1]).text
                if pair != single[i] + "\n" + single[i + 1] { hit[i] = true; hit[i + 1] = true }
            }
        }
        var out: [MaskBox] = []
        for (i, l) in lines.enumerated() {
            if hit[i] { out.append(MaskBox(rect: l.bbox, reason: .redacted)) }
            else if l.confidence < minConfidence { out.append(MaskBox(rect: l.bbox, reason: .lowConfidence)) }
        }
        return out
    }

    /// Drops only a box that lies entirely inside another box, so three passes over the same line
    /// paint and count it once. A partly covered box is always kept: if the layout pass saw a
    /// token as x 100-1450 and the plain pass as x 100-1600, dropping the second would leave the
    /// last characters visible. Dropping a fully contained box is safe because the padding grows
    /// with height, so the padded inner box stays inside the padded outer one. A redacted box
    /// wins over a low-confidence one.
    static func dedupe(_ boxes: [MaskBox]) -> [MaskBox] {
        let ordered = boxes.filter { $0.reason == .redacted } + boxes.filter { $0.reason == .lowConfidence }
        var kept: [MaskBox] = []
        for b in ordered where !kept.contains(where: { covered(b.rect, by: $0.rect) }) { kept.append(b) }
        return kept
    }

    /// True when all of `r` lies inside `by` (half a pixel of slack for rounding). Anything less
    /// counts as not covered, so the part that sticks out still gets painted.
    static func covered(_ r: CGRect, by: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return true }
        return by.insetBy(dx: -0.5, dy: -0.5).contains(r)
    }

    /// The padding around a box: at least 4 px, and a fifth of the line height on taller text,
    /// since Vision's boxes hug the glyphs and descenders or antialiasing can poke out.
    public static func pad(for r: CGRect) -> CGFloat { max(4, (r.height * 0.2).rounded(.up)) }

    /// The padded rectangle actually painted, clipped to the image.
    public static func painted(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let p = pad(for: r)
        return r.insetBy(dx: -p, dy: -p).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws `image` into a fresh 8-bit RGBA canvas of the same pixel size and fills each padded
    /// box with opaque black. Boxes are top-left origin; CoreGraphics is bottom-left, so y flips.
    public static func paint(_ image: CGImage, boxes: [MaskBox]) throws -> CGImage {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "cannot create a \(w)x\(h) canvas")
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for b in boxes {
            let r = painted(b.rect, width: w, height: h)
            guard !r.isEmpty else { continue }
            ctx.fill(CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
        }
        guard let out = ctx.makeImage() else { throw Failure(message: "cannot render the masked image") }
        return out
    }

    /// Mask, then OCR the masked copy again: anything it still flags outside the painted area is
    /// added and painted too, up to `maxRounds`. If the last re-read still finds something new,
    /// this throws rather than hand back a copy that may still show a secret.
    public static func mask(_ image: CGImage, redactor: Redactor, minConfidence: Float) throws -> MaskResult {
        // The counts the user sees match a plain `cheapshot --json` run of the same image.
        let shown = try OCR.recognizeLayout(image: image, minConfidence: minConfidence)
        let report = redactor.redact(Layout.text(shown)).report

        var boxes = try findBoxes(in: image, redactor: redactor, minConfidence: minConfidence)
        var masked = try paint(image, boxes: boxes)
        for round in 1...maxRounds {
            let again = try findBoxes(in: masked, redactor: redactor, minConfidence: minConfidence)
            let paintedRects = boxes.map { painted($0.rect, width: image.width, height: image.height) }
            let fresh = again.filter { b in !paintedRects.contains(where: { covered(b.rect, by: $0) }) }
            if fresh.isEmpty { return MaskResult(image: masked, boxes: boxes, report: report, rounds: round) }
            boxes += fresh
            masked = try paint(image, boxes: boxes)
        }
        throw Failure(message: "the masked copy still showed risky text after \(maxRounds) rounds; nothing was written")
    }

    /// PNG bytes, lossless, so a box stays exactly black (a JPEG would smear the edges).
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "cannot create a PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "cannot encode the PNG") }
        return data as Data
    }
}
