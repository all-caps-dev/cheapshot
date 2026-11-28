// Swift. ImageLoader reads image files with ImageIO only, so Core builds on iOS (AppKit's NSImage
// does not exist there). Until this change it used NSImage. These tests pin the ImageIO loader to
// NSImage's output on every EXIF orientation in PNG, JPEG and HEIC, so the switch cannot change
// what Vision reads and therefore cannot change what gets redacted.
//
// The fixtures are synthetic: a white 300x100 image with a red block in its stored top-left corner
// and a thin blue bar, so a wrong rotation or mirror moves pixels and fails the comparison.
import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
@testable import CheapshotCore

final class ImageLoaderTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    static let width = 300, height = 100

    /// The stored (not rotated) pixels every fixture starts from.
    func storedImage() throws -> CGImage {
        let w = Self.width, h = Self.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CoreGraphics is bottom-left, so the stored top-left corner is y = h - 20.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - 20, width: 30, height: 20))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 100, y: 40, width: 7, height: 50))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Writes the stored image as `type` with EXIF `orientation` and returns the file URL.
    func fixture(_ type: UTType, orientation: Int) throws -> URL {
        let url = tmp.appendingPathComponent("o\(orientation).\(type.preferredFilenameExtension ?? "img")")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try storedImage(), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(url.lastPathComponent)")
        return url
    }

    /// Every pixel drawn into one 8-bit sRGB RGBA buffer, so two decodes that differ only in
    /// alpha layout or row padding compare equal, and any real pixel difference does not.
    func rgba(_ image: CGImage) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buf
    }

    static let types: [UTType] = [.png, .jpeg, .heic]

    // MARK: - ImageIO decode, on every platform

    func testDecodeTurnsEveryOrientationUpright() throws {
        for type in Self.types {
            for o in 1...8 {
                let url = try fixture(type, orientation: o)
                let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try XCTUnwrap(ImageLoader.decode(src), "\(url.lastPathComponent) did not decode")
                // Orientations 5 to 8 turn the image a quarter, so width and height swap.
                let (w, h) = o >= 5 ? (Self.height, Self.width) : (Self.width, Self.height)
                XCTAssertEqual(image.width, w, url.lastPathComponent)
                XCTAssertEqual(image.height, h, url.lastPathComponent)
                XCTAssertEqual(ImageLoader.orientedSize(src)?.width, w, url.lastPathComponent)
                XCTAssertEqual(ImageLoader.orientedSize(src)?.height, h, url.lastPathComponent)
            }
        }
    }

    func testOrientationOneIsTheFileDecodedAsIs() throws {
        // The common case (every macOS screenshot) must be ImageIO's own decode, untouched.
        let url = try fixture(.png, orientation: 1)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let plain = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let loaded = try XCTUnwrap(ImageLoader.decode(src))
        XCTAssertEqual(loaded.dataProvider?.data as Data?, plain.dataProvider?.data as Data?)
        XCTAssertEqual(loaded.alphaInfo, plain.alphaInfo)
    }

    func testLoadDataMatchesLoadPath() throws {
        // A pasted image arrives as bytes, never a file; it must decode exactly like the file.
        for type in Self.types {
            let url = try fixture(type, orientation: 6)
            let fromPath = try XCTUnwrap(ImageLoader.load(path: url.path))
            let fromData = try XCTUnwrap(ImageLoader.load(data: try Data(contentsOf: url)))
            XCTAssertEqual(try rgba(fromPath), try rgba(fromData), url.lastPathComponent)
            XCTAssertEqual(ImageLoader.pixelSize(data: try Data(contentsOf: url))?.width, Self.height)
        }
    }

    func testUnreadableInputIsNil() throws {
        let junk = tmp.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertNil(ImageLoader.load(path: junk.path))
        XCTAssertNil(ImageLoader.pixelSize(path: junk.path))
        XCTAssertNil(ImageLoader.load(path: tmp.appendingPathComponent("missing.png").path))
        XCTAssertNil(ImageLoader.load(data: Data()))
    }

    // MARK: - parity with the NSImage loader it replaced (macOS only, where NSImage exists)

    #if canImport(AppKit)
    func testImageIODecodeMatchesNSImagePixelForPixelOnEveryOrientation() throws {
        for type in Self.types {
            for o in 1...8 {
                let url = try fixture(type, orientation: o)
                let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let ours = try XCTUnwrap(ImageLoader.decode(src))
                let ns = try XCTUnwrap(NSImage(contentsOfFile: url.path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(ours.width, ns.width, url.lastPathComponent)
                XCTAssertEqual(ours.height, ns.height, url.lastPathComponent)
                XCTAssertEqual(try rgba(ours), try rgba(ns), "\(url.lastPathComponent): pixels differ from NSImage")
                let rep = try XCTUnwrap(NSImage(contentsOfFile: url.path)?.representations.first)
                XCTAssertEqual(ImageLoader.orientedSize(src)?.width, rep.pixelsWide, url.lastPathComponent)
                XCTAssertEqual(ImageLoader.orientedSize(src)?.height, rep.pixelsHigh, url.lastPathComponent)
            }
        }
    }

    func testSVGStillLoadsThroughTheAppKitFallbackOnMacOS() throws {
        // ImageIO cannot open SVG; NSImage can, and the CLI used to accept it. Keep that on macOS.
        let svg = tmp.appendingPathComponent("t.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="50"><rect width="200" height="50" fill="white"/></svg>"#.utf8).write(to: svg)
        XCTAssertNil(CGImageSourceCreateWithURL(svg as CFURL, nil).flatMap { ImageLoader.decode($0) })
        let image = try XCTUnwrap(ImageLoader.load(path: svg.path))
        XCTAssertEqual(image.width, 200)
        // NSImage reports an SVG's pixel size as 0x0, and the CLI has always used that.
        XCTAssertEqual(ImageLoader.pixelSize(path: svg.path)?.width, 0)
    }
    #endif
}
