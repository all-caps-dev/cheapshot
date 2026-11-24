// Swift. NOV-117: no location or device metadata may reach an agent through `cheapshot mask` or
// `cheapshot allow`. The fixtures are synthetic photos written here with ImageIO, tagged with a
// fake GPS position, camera make and model, capture date, IPTC city and an XMP field, and the
// tests check the copies numerically and by walking the file bytes. Nothing here looks at pixels
// by eye.
import XCTest
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers
@testable import CheapshotCLI
@testable import CheapshotCore

final class StripMetadataTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], interactive: Bool = false) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        let env = ["CHEAPSHOT_HOME": tmp.path, "TMPDIR": tmp.path]   // ledger, allow file and copies stay in tmp
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { "" },
                       environment: env, home: tmp.path, isInteractive: interactive)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    // Fake values that are easy to search for in the output bytes. None is a real place or device.
    static let make = "FakeCamMake", model = "FakeCamModel9", software = "FakeCamOS", city = "FakeTownIPTC"
    static let xmpCity = "FakeTownXMP", taken = "2026:11:24 01:03:00"

    /// A 120x80 white image with a 20x20 red square in its stored top-left corner, written as
    /// `type` (PNG or JPEG) with every kind of metadata the task names, and EXIF `orientation`.
    func makePhoto(_ name: String, type: UTType, orientation: Int = 1) throws -> URL {
        let w = 120, h = 80
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CoreGraphics is bottom-left, so the stored top-left corner is y = h - 20.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - 20, width: 20, height: 20))
        let img = try XCTUnwrap(ctx.makeImage())

        // Step 1: the EXIF, GPS, TIFF and IPTC dictionaries, through the plain properties route.
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7557, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 73.8831, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: Self.make, kCGImagePropertyTIFFModel: Self.model,
                                             kCGImagePropertyTIFFSoftware: Self.software],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: Self.taken],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: Self.city],
        ]
        let first = NSMutableData()
        let d1 = try XCTUnwrap(CGImageDestinationCreateWithData(first, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d1, img, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(d1))

        // Step 2: re-write with that file's metadata plus one XMP field (photoshop:City).
        let src = try XCTUnwrap(CGImageSourceCreateWithData(first, nil))
        let meta = try XCTUnwrap(CGImageMetadataCreateMutableCopy(try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(src, 0, nil))))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "photoshop:City" as CFString, Self.xmpCity as CFString))
        let url = tmp.appendingPathComponent(name)
        let d2 = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(d2, img, meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d2))

        // The fixture must really carry what the copy is meant to lose, or the test proves nothing.
        let check = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(p[kCGImagePropertyGPSDictionary], "fixture \(name) has no GPS")
        XCTAssertEqual((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, Self.make)
        XCTAssertEqual((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, orientation)
        let m = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(check, 0, nil))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(m, nil, "photoshop:City" as CFString), "fixture \(name) has no XMP")
        return url
    }

    /// Every way the copy could still carry metadata, checked three ways: ImageIO's parsed
    /// properties, the PNG chunk list, and a byte search for the fake values.
    func assertNoMetadata(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Data(contentsOf: url)
        // 1. ImageIO's view.
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertNil(p[kCGImagePropertyGPSDictionary], "GPS survived", file: file, line: line)
        XCTAssertNil(p[kCGImagePropertyIPTCDictionary], "IPTC survived", file: file, line: line)
        XCTAssertNil(p[kCGImagePropertyMakerAppleDictionary], "Apple MakerNote survived", file: file, line: line)
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware] {
            XCTAssertNil(tiff[k], "TIFF \(k) survived", file: file, line: line)
        }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for k in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifMakerNote, kCGImagePropertyExifUserComment] {
            XCTAssertNil(exif[k], "Exif \(k) survived", file: file, line: line)
        }
        XCTAssertEqual((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1, "an orientation tag survived", file: file, line: line)
        if let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            XCTAssertNil(CGImageMetadataCopyTagWithPath(m, nil, "photoshop:City" as CFString), "XMP survived", file: file, line: line)
        }
        // 2. The PNG chunks: only image data, colour and pixel-density chunks. eXIf, tEXt, zTXt
        //    and iTXt (where XMP lives) are all metadata, so any of them fails.
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "not a PNG", file: file, line: line)
        let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "iCCP", "pHYs", "gAMA", "cHRM", "sBIT", "iDOT"]
        var i = 8, chunks: [String] = []
        while i + 8 <= data.count {
            let len = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            chunks.append(String(decoding: data[i + 4..<i + 8], as: UTF8.self))
            i += 12 + len
        }
        XCTAssertEqual(chunks.last, "IEND", "chunk walk did not end cleanly: \(chunks)", file: file, line: line)
        XCTAssertEqual(Set(chunks).subtracting(allowed), [], "metadata chunks in the copy: \(chunks)", file: file, line: line)
        // 3. The fake values and the EXIF / XMP markers appear nowhere in the bytes.
        for needle in [Self.make, Self.model, Self.software, Self.city, Self.xmpCity, Self.taken, "Exif\0\0", "xmpmeta", "GPS"] {
            XCTAssertNil(data.range(of: Data(needle.utf8)), "\(needle.debugDescription) found in the copy", file: file, line: line)
        }
    }

    /// RGBA of one pixel, top-left origin.
    func pixel(_ url: URL, x: Int, y: Int) throws -> (w: Int, h: Int, rgba: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let o = (y * img.width + x) * 4
        return (img.width, img.height, Array(buf[o..<o + 4]))
    }
    func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 70 && p[2] < 70 }
    func isWhite(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] > 200 && p[2] > 200 }

    // MARK: - mask

    func testMaskCopyOfGPSTaggedPNGAndJPEGCarriesNoMetadata() async throws {
        for (name, type) in [("gps.png", UTType.png), ("gps.jpg", UTType.jpeg)] {
            let src = try makePhoto(name, type: type)
            let out = tmp.appendingPathComponent("masked-\(name).png")
            let r = await run(["mask", "--out", out.path, src.path])
            XCTAssertEqual(r.code, 0, "\(name): \(r.err)")
            try assertNoMetadata(out)
        }
    }

    /// An iPhone-style JPEG stored sideways with EXIF orientation 6 ("rotate 90 degrees clockwise
    /// to display"). mask used to refuse it; now the copy is upright: 80x120, and the red square
    /// that sat in the stored top-left corner shows in the top-right.
    func testMaskAppliesEXIFOrientation() async throws {
        let src = try makePhoto("rotated.jpg", type: .jpeg, orientation: 6)
        let out = tmp.appendingPathComponent("rotated-masked.png")
        let r = await run(["mask", "--out", out.path, src.path])
        XCTAssertEqual(r.code, 0, r.err)
        let tr = try pixel(out, x: 70, y: 10), tl = try pixel(out, x: 10, y: 10)
        XCTAssertEqual(tr.w, 80); XCTAssertEqual(tr.h, 120)
        XCTAssertTrue(isRed(tr.rgba), "top-right should be red: \(tr.rgba)")
        XCTAssertTrue(isWhite(tl.rgba), "top-left should be white: \(tl.rgba)")
        try assertNoMetadata(out)
    }

    /// All eight orientations decode to the displayed size, and the mirrored ones too.
    func testEveryOrientationLoadsUpright() throws {
        for o in 1...8 {
            let src = try makePhoto("o\(o).png", type: .png, orientation: o)
            let img = try Masker.loadPixels(path: src.path)
            XCTAssertEqual([img.width, img.height], o >= 5 ? [80, 120] : [120, 80], "orientation \(o)")
        }
    }

    // MARK: - allow

    func testAllowOfAnImageWritesAStrippedCopyAndAllowsIt() async throws {
        let src = try makePhoto("IMG_0001.jpg", type: .jpeg, orientation: 6)
        let r = await run(["allow", src.path], interactive: true)
        XCTAssertEqual(r.code, 0, r.err)
        let entry = try String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)
        let f = try XCTUnwrap(entry.split(separator: "\n").last).split(separator: "\t").map(String.init)
        XCTAssertEqual(f.count, 4, entry)
        // Field 2 is the original (what the agent will Read), field 4 the copy it gets instead.
        XCTAssertEqual(f[1], CLI.absolutePath(src.path))
        let copy = URL(fileURLWithPath: f[3])
        XCTAssertTrue(copy.path.contains("/cheapshot-allowed/"), copy.path)
        XCTAssertTrue(copy.path.hasSuffix(".png"))
        XCTAssertNotEqual(copy.path, src.path)
        // Field 3 is the copy's SHA-256, so the hook can tell a swapped copy apart.
        let bytes = try Data(contentsOf: copy)
        XCTAssertEqual(f[2], SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try assertNoMetadata(copy)
        // The copy is upright too, and the person is told where it is.
        let tr = try pixel(copy, x: 70, y: 10)
        XCTAssertEqual([tr.w, tr.h], [80, 120]); XCTAssertTrue(isRed(tr.rgba), "\(tr.rgba)")
        XCTAssertTrue(r.out.contains(copy.path), r.out)
        XCTAssertTrue(r.out.contains("no location"), r.out)
        // The original is untouched.
        let still = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil)), 0, nil) as? [CFString: Any])
        XCTAssertNotNil(still[kCGImagePropertyGPSDictionary])
    }

    /// NOV-117 review: the copy is unredacted pixels, so it is 0600 in a 0700 folder, a stale
    /// copy from an earlier allow is swept, and a folder that is not private is refused.
    func testAllowCopyIsPrivateAndStaleCopiesAreSwept() async throws {
        let src = try makePhoto("p.png", type: .png)
        let dir = tmp.appendingPathComponent("cheapshot-allowed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stale = dir.appendingPathComponent("old-allowed.png")
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stale.path)
        let r = await run(["allow", src.path], interactive: true)
        XCTAssertEqual(r.code, 0, r.err)
        let entry = try String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)
        let copy = String(try XCTUnwrap(entry.split(separator: "\n").last).split(separator: "\t")[3])
        let mode = { (p: String) in (try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)?.intValue }
        XCTAssertEqual(try mode(copy), 0o600)
        XCTAssertEqual(try mode(dir.path), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a stale copy must be swept")

        // A folder with loose permissions, or a symlink in its place, is refused, not used.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let loose = await run(["allow", src.path], interactive: true)
        XCTAssertEqual(loose.code, 1); XCTAssertTrue(loose.err.contains("not 700"), loose.err)
        try FileManager.default.removeItem(at: dir)
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: elsewhere)
        let link = await run(["allow", src.path], interactive: true)
        XCTAssertEqual(link.code, 1); XCTAssertTrue(link.err.contains("not a plain directory"), link.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// NOV-117 review: a multi-frame image keeps only its first frame, and allow says so.
    func testAllowOfAnAnimatedGIFSaysFirstFrameOnly() async throws {
        let url = tmp.appendingPathComponent("anim.gif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for shade in [0.0, 0.5, 1.0] {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let r = await run(["allow", url.path], interactive: true)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("first frame of 3 only"), r.out)
        XCTAssertTrue(r.out.contains("8-bit sRGB PNG"), r.out)
        let one = try makePhoto("one.png", type: .png)
        let s = await run(["allow", one.path], interactive: true)
        XCTAssertFalse(s.out.contains("first frame of"), s.out)
    }

    /// An image allow that cannot make its copy allows nothing: never the raw file as a fallback.
    func testAllowOfAnUnreadableImageAllowsNothing() async throws {
        let bogus = tmp.appendingPathComponent("not-really.jpg")
        try Data("not an image".utf8).write(to: bogus)
        for path in [bogus.path, tmp.appendingPathComponent("missing.png").path] {
            let r = await run(["allow", path], interactive: true)
            XCTAssertEqual(r.code, 1, r.out)
            XCTAssertTrue(r.err.contains("nothing was allowed"), r.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cheapshot-allow").path))
    }
}
