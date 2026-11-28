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
        /// Why `mask` gave up, so a caller can pick an exit code without matching message text.
        public enum Kind: Equatable {
            /// OCR could not prove the copy safe: the blank-screenshot gate (`blankRefusal`) or
            /// risky text still showing after `maxRounds`. Often a cold start, so a retry may work.
            case unconfirmed
            /// Anything else: a canvas, render, encode or decode failure. A retry will not help.
            case error
        }
        public let message: String
        public let kind: Kind
        public init(message: String, kind: Kind = .error) { self.message = message; self.kind = kind }
        public var description: String { message }
    }

    /// Give up after this many rounds of "mask, re-read the masked copy, mask what it still finds".
    public static let maxRounds = 3

    /// Loads the image straight from the file with ImageIO, so the CGImage is exactly the file's
    /// pixel grid. Running OCR on this same CGImage keeps the boxes and the painting in one pixel
    /// space, whatever DPI the file claims (a @2x screenshot is 144 DPI; NSImage would size it in
    /// points). An EXIF rotation (iPhone photos, many JPEG and HEIC files) is applied here, so
    /// Vision reads upright text and the copy is written upright with no orientation tag (NOV-117).
    /// A CGImage carries pixels and a colour space only: no EXIF, GPS, TIFF, IPTC or XMP.
    public static func loadPixels(path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure(message: "cannot read image \(path)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1 else {
            // Upright: decode as is, so the copy matches the file pixel for pixel.
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw Failure(message: "cannot decode image \(path)")
            }
            return image
        }
        guard (2...8).contains(orientation) else {
            throw Failure(message: "\(path) has an unknown EXIF orientation (\(orientation))")
        }
        // Rotated or mirrored: ask ImageIO for a full-size "thumbnail" with the orientation
        // applied. MaxPixelSize is the longest side, so nothing is scaled down, and
        // FromImageAlways decodes the real image rather than a small embedded preview.
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { throw Failure(message: "\(path) does not say its pixel size") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw Failure(message: "cannot decode image \(path)")
        }
        // Orientations 5 to 8 turn the image a quarter, so width and height swap.
        let (ew, eh) = orientation >= 5 ? (h, w) : (w, h)
        guard image.width == ew, image.height == eh else {
            throw Failure(message: "\(path): rotating it gave \(image.width)x\(image.height), expected \(ew)x\(eh)")
        }
        return image
    }

    /// The pixels of `path`, upright, as PNG bytes with no metadata: what `cheapshot allow`
    /// hands an agent in place of the original file (NOV-117). Drawn into a fresh 8-bit sRGB
    /// canvas (`paint` with no boxes), so even a camera's own colour profile does not come along.
    /// Only the first frame is kept; `frames` says how many the file had (an animated GIF, a
    /// multi-page TIFF) so the caller can say so.
    public static func strippedPNG(path: String) throws -> (data: Data, width: Int, height: Int, frames: Int) {
        let image = try paint(try loadPixels(path: path), boxes: [])
        let frames = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 1
        return (try pngData(image), image.width, image.height, frames)
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

    /// The refusal `mask` throws when `refusesBlank` says no. True whether the warm passes saw no
    /// text at all or saw clean text that produced no box, and never names the allow command.
    static let blankRefusal = "OCR could not confirm a complete read of what looks like a screenshot, even after a retry, so nothing was masked or written; a person can approve the original from a terminal"

    /// The CHE-24 gate, pure so it can be unit-tested without Vision (MaskGateTests).
    ///
    /// A screenshot-like image whose checked read was not `.ok`, after the retry, is a likely OCR
    /// failure, not a text-free image: masking on would paint nothing and allow a copy that is the
    /// original, so the model would get the raw pixels the mask was meant to keep from it. Fail
    /// closed instead: no copy, no allow entry. A non-screenshot-like image (a photo) is not retried
    /// and not gated: an empty read there is an answer, not a failure.
    ///
    /// Keyed on `screenshotLike` and "anything but .ok" rather than `retried && .empty`, so a future
    /// status or a change to when the retry runs still fails closed here. The checked lines are
    /// filtered at the floor, so faint text alone also reads as empty there; the confidence-0 passes
    /// in `findBoxes` still see it and paint it as low-confidence, so `boxes` is non-empty and this
    /// lets it through. It keys on boxes, not lines: if the checked read cold-failed and a warmer
    /// pass saw only clean lines above the floor, there is nothing to paint and the copy would be
    /// the original, so that still refuses.
    static func refusesBlank(screenshotLike: Bool, status: OCR.Status, boxes: [MaskBox]) -> Bool {
        screenshotLike && status != .ok && boxes.isEmpty
    }

    /// Mask, then OCR the masked copy again: anything it still flags outside the painted area is
    /// added and painted too, up to `maxRounds`. If the last re-read still finds something new,
    /// this throws rather than hand back a copy that may still show a secret.
    public static func mask(_ image: CGImage, redactor: Redactor, minConfidence: Float) throws -> MaskResult {
        // The same checked OCR the read path uses, cold-start retry included (CHE-24).
        let checked = try OCR.recognizeLayoutChecked(image: image, minConfidence: minConfidence)
        let firstBoxes = try findBoxes(in: image, redactor: redactor, minConfidence: minConfidence)
        if refusesBlank(screenshotLike: checked.screenshotLike, status: checked.status, boxes: firstBoxes) {
            throw Failure(message: blankRefusal, kind: .unconfirmed)
        }
        // The counts the user sees match a plain `cheapshot --json` run of the same image.
        let shown = checked.lines
        let report = redactor.redact(Layout.text(shown)).report

        var boxes = firstBoxes
        var masked = try paint(image, boxes: boxes)
        for round in 1...maxRounds {
            let again = try findBoxes(in: masked, redactor: redactor, minConfidence: minConfidence)
            let paintedRects = boxes.map { painted($0.rect, width: image.width, height: image.height) }
            let fresh = again.filter { b in !paintedRects.contains(where: { covered(b.rect, by: $0) }) }
            if fresh.isEmpty { return MaskResult(image: masked, boxes: boxes, report: report, rounds: round) }
            boxes += fresh
            masked = try paint(image, boxes: boxes)
        }
        throw Failure(message: "the masked copy still showed risky text after \(maxRounds) rounds; nothing was written",
                      kind: .unconfirmed)
    }

    /// PNG bytes, lossless, so a box stays exactly black (a JPEG would smear the edges).
    /// A CGImage holds pixels and a colour space only, so no GPS, camera or date metadata can
    /// come from the source. ImageIO still writes an eXIf chunk of its own (colour space and
    /// pixel size), so the text and EXIF chunks are dropped after encoding: the file holds
    /// only image and colour chunks (NOV-117, StripMetadataTests walks the chunks).
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "cannot create a PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "cannot encode the PNG") }
        return try dropMetadataChunks(data as Data)
    }

    /// PNG chunks that hold metadata rather than pixels: EXIF, the three text kinds (XMP lives
    /// in iTXt) and the modification time.
    static let metadataChunks: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"]

    /// Copies a PNG chunk by chunk, leaving out `metadataChunks`. A PNG is an 8-byte signature,
    /// then chunks of [4-byte big-endian length][4-byte type][data][4-byte CRC]. Each chunk's CRC
    /// covers only itself, so dropping whole chunks leaves the rest valid.
    static func dropMetadataChunks(_ png: Data) throws -> Data {
        let bytes = [UInt8](png)
        guard bytes.count >= 8, bytes[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw Failure(message: "the PNG encoder wrote something that is not a PNG")
        }
        var out = Data(bytes[0..<8])
        var i = 8
        while i + 12 <= bytes.count {
            let length = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = i + 12 + length
            guard end <= bytes.count else { throw Failure(message: "the PNG encoder wrote a truncated chunk") }
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            if !metadataChunks.contains(type) { out.append(contentsOf: bytes[i..<end]) }
            i = end
        }
        guard i == bytes.count else { throw Failure(message: "the PNG encoder wrote trailing bytes") }
        return out
    }
}
