// Swift. Turns an image file (or the bytes of one) into the upright CGImage that OCR reads.
//
// It uses ImageIO, which exists on macOS and iOS alike. It used to use AppKit's NSImage, which
// does not exist on iOS. The ImageIO path is pinned to NSImage's output pixel for pixel on every
// EXIF orientation (ImageLoaderTests), so the switch does not change what Vision reads.
import Foundation
import CoreGraphics
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

public enum ImageLoader {
    /// The upright image in a file, or nil when it cannot be read.
    public static func load(path: String) -> CGImage? {
        if let src = source(path: path), let image = decode(src) { return image }
        return appKitFallback(path: path)?.image
    }

    /// The upright image in a file's bytes, for a pasted or dropped image that never touched disk.
    public static func load(data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(decode)
    }

    /// The file's pixel size after its EXIF orientation is applied, which is the size the image
    /// would cost an agent to look at.
    public static func pixelSize(path: String) -> (width: Int, height: Int)? {
        if let src = source(path: path), let size = orientedSize(src) { return size }
        return appKitFallback(path: path)?.size
    }

    /// Same as ``pixelSize(path:)`` for an image held in memory.
    public static func pixelSize(data: Data) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(orientedSize)
    }

    // MARK: - ImageIO

    static func source(path: String) -> CGImageSource? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    }

    /// EXIF orientation 1 to 8 of the first image, 1 when the file does not say.
    static func orientation(_ src: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let o = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (1...8).contains(o) ? o : 1
    }

    /// The first image (the first frame of a GIF), turned upright.
    ///
    /// Upright files (every macOS screenshot) are ImageIO's own decode, untouched. A rotated or
    /// mirrored file is decoded the same way and then drawn into an upright bitmap. This matches
    /// NSImage exactly. ImageIO's "thumbnail with transform" shortcut, which `Masker.loadPixels`
    /// uses, decodes lossy HEIC slightly differently, so it is not used here.
    static func decode(_ src: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(src) > 0, let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let o = orientation(src)
        guard o != 1 else { return raw }
        return upright(raw, orientation: o)
    }

    /// Width and height after the orientation is applied: 5 to 8 turn the image a quarter.
    static func orientedSize(_ src: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return orientation(src) >= 5 ? (h, w) : (w, h)
    }

    /// Draws `image` into a new 8-bit sRGB bitmap with the EXIF `orientation` undone.
    ///
    /// CoreGraphics puts the origin at the bottom left, and each transform below maps the stored
    /// image's rectangle (w by h) onto the upright canvas. EXIF numbers each case by where the
    /// stored first row and first column end up: 2 mirrors left-right, 3 turns 180 degrees,
    /// 4 mirrors top-bottom, 5 to 8 are the quarter turns, with or without a mirror.
    static func upright(_ image: CGImage, orientation o: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let quarterTurn = o >= 5
        let canvasW = quarterTurn ? image.height : image.width
        let canvasH = quarterTurn ? image.width : image.height
        let t: CGAffineTransform
        switch o {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return image
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - AppKit fallback (macOS only)

    /// Formats ImageIO cannot open but NSImage can, which in practice means SVG. The CLI has
    /// always accepted those through NSImage, so macOS keeps them. iOS has no fallback.
    static func appKitFallback(path: String) -> (image: CGImage, size: (width: Int, height: Int))? {
        #if canImport(AppKit)
        // With no hints, NSImage renders a vector image at the main screen's backing scale, so an
        // SVG came out 2x on a Retina Mac and 1x elsewhere. An identity transform pins it to 1x
        // (one pixel per point) on every host, like the ImageIO path, which never scales.
        let oneX: [NSImageRep.HintKey: Any] = [.ctm: NSAffineTransform()]
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: oneX),
              let rep = img.representations.first else { return nil }
        return (cg, (rep.pixelsWide, rep.pixelsHigh))
        #else
        return nil
        #endif
    }
}
