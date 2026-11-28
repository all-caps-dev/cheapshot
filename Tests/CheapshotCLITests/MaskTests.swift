// Swift. Tests for `cheapshot mask` (NOV-95). The fixture is drawn here with CoreText, so the
// test knows exactly where each line's ink is, then checked by sampling pixels: never by eye.
import XCTest
import ImageIO
import CoreGraphics
import CoreText
@testable import CheapshotCLI
import CryptoKit
@testable import CheapshotCore

final class MaskTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-mask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], tmpdir: String? = nil) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        let env = ["CHEAPSHOT_HOME": tmp.path, "TMPDIR": tmpdir ?? tmp.path]   // ledger and allow file stay in tmp
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { "" },
                       environment: env, home: tmp.path, isInteractive: false)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    // Fake values, built from parts so no whole token sits in one literal. Neither is a real credential.
    static let fakeToken = "ghp_" + "Fake1234Test5678" + "Demo9012Abcd"
    static let fakePhone = "(212) 555" + "-0147"

    /// Lines drawn into the fixture, top to bottom, and where each one's ink landed (pixels,
    /// top-left origin), so a test can sample inside a box.
    struct Fixture { var url: URL; var width: Int; var height: Int; var ink: [String: CGRect] }

    /// A "@2x screenshot": pixel size twice the point size, written with 144 DPI the way macOS
    /// writes Retina captures. If the boxes were in points rather than pixels, the paint would
    /// land in the top-left quarter and the secret's samples below would fail.
    func makeFixture(lines: [String], name: String = "shot@2x.png") throws -> Fixture {
        let scale: CGFloat = 2, wPt: CGFloat = 900, rowPt: CGFloat = 60
        let w = Int(wPt * scale), h = Int((CGFloat(lines.count) * rowPt + 40) * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Menlo" as CFString, 22 * scale, nil)
        var ink: [String: CGRect] = [:]
        for (i, s) in lines.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                  kCTForegroundColorAttributeName as NSAttributedString.Key:
                                                                    CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            let baselineFromTop = (CGFloat(i) * rowPt + 50) * scale
            let origin = CGPoint(x: 40 * scale, y: CGFloat(h) - baselineFromTop)   // CG is bottom-left
            ctx.textPosition = origin
            // The glyphs' ink box, read before drawing (CTLineDraw moves the text position to the
            // end of the line), then flipped back to top-left pixels.
            let b = CTLineGetImageBounds(line, ctx)
            CTLineDraw(line, ctx)
            ink[s] = CGRect(x: b.minX, y: CGFloat(h) - b.maxY, width: b.width, height: b.height)
        }
        let img = try XCTUnwrap(ctx.makeImage())
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return Fixture(url: url, width: w, height: h, ink: ink)
    }

    /// RGBA bytes of a PNG on disk, in its own pixel grid.
    func pixels(_ url: URL) throws -> (w: Int, h: Int, rgba: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (img.width, img.height, buf)
    }

    /// Fraction of pixels in `r` (top-left origin) that are pure opaque black. The buffer rows run
    /// top to bottom, matching the top-left boxes.
    func blackFraction(_ p: (w: Int, h: Int, rgba: [UInt8]), in r: CGRect) -> Double {
        let x0 = max(0, Int(r.minX)), x1 = min(p.w, Int(r.maxX.rounded(.up)))
        let y0 = max(0, Int(r.minY)), y1 = min(p.h, Int(r.maxY.rounded(.up)))
        var black = 0, total = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let i = (y * p.w + x) * 4
            total += 1
            if p.rgba[i] == 0, p.rgba[i + 1] == 0, p.rgba[i + 2] == 0, p.rgba[i + 3] == 255 { black += 1 }
        } }
        return total == 0 ? 0 : Double(black) / Double(total)
    }

    /// Count of pixels in `r` that differ between two images of the same size.
    func changed(_ a: (w: Int, h: Int, rgba: [UInt8]), _ b: (w: Int, h: Int, rgba: [UInt8]), in r: CGRect) -> Int {
        let x0 = max(0, Int(r.minX)), x1 = min(a.w, Int(r.maxX.rounded(.up)))
        let y0 = max(0, Int(r.minY)), y1 = min(a.h, Int(r.maxY.rounded(.up)))
        var n = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let i = (y * a.w + x) * 4
            if a.rgba[i] != b.rgba[i] || a.rgba[i + 1] != b.rgba[i + 1] || a.rgba[i + 2] != b.rgba[i + 2] { n += 1 }
        } }
        return n
    }

    func testMaskPaintsSecretsAndLeavesNormalTextAlone() async throws {
        let normal = "Settings General Appearance"
        let token = "token " + Self.fakeToken
        let phone = "call " + Self.fakePhone
        let fx = try makeFixture(lines: [normal, token, phone])
        let out = tmp.appendingPathComponent("masked.png")

        let r = await run(["mask", "--json", "--out", out.path, fx.url.path])
        XCTAssertEqual(r.code, 0, r.err)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let counts = try XCTUnwrap(j["redactions"] as? [String: Int])
        XCTAssertGreaterThanOrEqual(counts["PHONE"] ?? 0, 1, "\(counts)")
        XCTAssertGreaterThanOrEqual((counts["GITHUB_PAT"] ?? 0) + (counts["TOKEN"] ?? 0), 1, "\(counts)")
        XCTAssertGreaterThanOrEqual(j["box_count"] as? Int ?? 0, 2, "\(j)")

        let before = try pixels(fx.url), after = try pixels(out)
        // Same pixel grid as the @2x source: no scaling anywhere.
        XCTAssertEqual(after.w, fx.width); XCTAssertEqual(after.h, fx.height)
        // Every pixel of the secrets' ink is now opaque black.
        XCTAssertEqual(blackFraction(after, in: try XCTUnwrap(fx.ink[token])), 1.0, accuracy: 0.0001)
        XCTAssertEqual(blackFraction(after, in: try XCTUnwrap(fx.ink[phone])), 1.0, accuracy: 0.0001)
        // The normal line is untouched, pixel for pixel.
        XCTAssertEqual(changed(before, after, in: try XCTUnwrap(fx.ink[normal])), 0)

        // The masked copy, and only it, got a one-shot allow line.
        let allow = try String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)
        XCTAssertTrue(allow.contains(out.path), allow)
        XCTAssertFalse(allow.contains(fx.url.path), "the source must never be allowed by mask")
    }

    func testCleanImageGetsNoBoxesAndIsUnchanged() async throws {
        let fx = try makeFixture(lines: ["Display Brightness", "Night Shift Schedule"])
        let out = tmp.appendingPathComponent("clean.png")
        let r = await run(["mask", "--out", out.path, fx.url.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("boxes: 0 "), r.out)
        let a = try pixels(fx.url), b = try pixels(out)
        XCTAssertEqual(changed(a, b, in: CGRect(x: 0, y: 0, width: a.w, height: a.h)), 0)
    }

    func testDefaultOutputGoesToScratchNotNextToSource() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let r = await run(["mask", fx.url.path])
        XCTAssertEqual(r.code, 0, r.err)
        let line = try XCTUnwrap(r.out.split(separator: "\n").first { $0.hasPrefix("masked: ") })
        let path = String(line.dropFirst("masked: ".count))
        XCTAssertTrue(path.contains("/cheapshot-masked/"), path)
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// PR #18 review: the mask's allow entry carries the SHA-256 of the copy it wrote, so the
    /// hook can refuse a file swapped in afterwards.
    func testAllowEntryCarriesTheCopysHash() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let r = await run(["mask", fx.url.path])
        XCTAssertEqual(r.code, 0, r.err)
        let line = try XCTUnwrap(r.out.split(separator: "\n").first { $0.hasPrefix("masked: ") })
        let path = String(line.dropFirst("masked: ".count))
        let entry = try String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)
        let fields = try XCTUnwrap(entry.split(separator: "\n").last).split(separator: "\t").map(String.init)
        XCTAssertEqual(fields.count, 3, entry)
        XCTAssertEqual(fields[1], path)
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fields[2], digest)
    }

    /// PR #18 second review: no run of mask may write an allow line for any path but its copy.
    func testNewlineInOutForgesNoAllowLine() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let forged = tmp.appendingPathComponent("a\n9999999999\t/tmp/secret.png\n/tmp/y.png").path
        let r = await run(["mask", "--out", forged, fx.url.path])
        XCTAssertNotEqual(r.code, 0, r.out)
        let entry = (try? String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)) ?? ""
        XCTAssertFalse(entry.contains("secret.png"), entry)
        // The shared writer refuses too, so `allow` and any future caller are covered.
        let io = CLIIO(out: { _ in }, err: { _ in }, readStdin: { "" }, environment: ["TMPDIR": tmp.path], home: tmp.path)
        XCTAssertNil(CLI.writeAllowEntry("/tmp/x\n1\t/tmp/secret.png", io))
        let after = (try? String(contentsOf: tmp.appendingPathComponent("cheapshot-allow"), encoding: .utf8)) ?? ""
        XCTAssertFalse(after.contains("secret.png"), after)
    }

    func testNeverOverwrites() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let original = try Data(contentsOf: fx.url)
        // --out naming the source, then --out naming some other existing file: both refused.
        let a = await run(["mask", "--out", fx.url.path, fx.url.path])
        XCTAssertEqual(a.code, 1)
        let other = tmp.appendingPathComponent("exists.png")
        try Data("x".utf8).write(to: other)
        let b = await run(["mask", "--out", other.path, fx.url.path])
        XCTAssertEqual(b.code, 1)
        XCTAssertEqual(try Data(contentsOf: fx.url), original)
        XCTAssertEqual(try Data(contentsOf: other), Data("x".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cheapshot-allow").path),
                       "a failed mask must not allow anything")
    }

    // MARK: - CS-18: private copies, stale sweep

    /// The file's low 9 permission bits, or -1 when it cannot be statted.
    func mode(_ path: String) -> Int {
        var st = stat()
        guard stat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode) & 0o777
    }

    /// CS-18: a masked copy is a redacted image of the screen, so only its owner reads it:
    /// mode 0600, at --out and at the default scratch spot alike.
    func testMaskedCopyIsMode0600() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let out = tmp.appendingPathComponent("explicit.png")
        let a = await run(["mask", "--json", "--out", out.path, fx.url.path])
        XCTAssertEqual(a.code, 0, a.err)
        XCTAssertEqual(mode(out.path), 0o600, out.path)

        let b = await run(["mask", fx.url.path])
        XCTAssertEqual(b.code, 0, b.err)
        let line = try XCTUnwrap(b.out.split(separator: "\n").first { $0.hasPrefix("masked: ") })
        let defaulted = String(line.dropFirst("masked: ".count))
        XCTAssertEqual(mode(defaulted), 0o600, defaulted)
    }

    /// CS-18: the sweeper takes only regular files older than the age it is given, in the one
    /// folder it is given, and leaves symlinks and newer files alone.
    func testSweepTakesOnlyOldRegularFilesInTheGivenFolder() throws {
        let dir = tmp.appendingPathComponent("sweep-standin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.png")
        let recent = dir.appendingPathComponent("recent.png")
        try Data("o".utf8).write(to: old)
        try Data("n".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: old.path)
        // The link points at an old file outside the folder: a sweep that followed links would
        // see an old regular file and remove the link (or worse, the target).
        let outside = tmp.appendingPathComponent("outside-old.png")
        try Data("t".utf8).write(to: outside)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: outside.path)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let sub = dir.appendingPathComponent("older-dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: sub.path)

        CLI.sweepStale(in: dir, olderThan: 3600)

        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "a recent file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "an old regular file goes")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "a symlink stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a link's target is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path), "a subdirectory stays")
    }

    /// CS-18: a mask run into the default folder sweeps that folder's stale copies first. An
    /// explicit --out never has its folder swept.
    func testMaskRunSweepsTheDefaultFolderOnly() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let maskedDir = tmp.appendingPathComponent("cheapshot-masked")
        try FileManager.default.createDirectory(at: maskedDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let old = maskedDir.appendingPathComponent("old-masked.png")
        let recent = maskedDir.appendingPathComponent("recent-masked.png")
        try Data("o".utf8).write(to: old)
        try Data("n".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: old.path)

        let defaulted = await run(["mask", fx.url.path])
        XCTAssertEqual(defaulted.code, 0, defaulted.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "the recent copy stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the stale copy is swept")

        // An explicit --out elsewhere: a stale file beside it is not touched.
        let outDir = tmp.appendingPathComponent("out-elsewhere")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let staleBeside = outDir.appendingPathComponent("stale.png")
        try Data("s".utf8).write(to: staleBeside)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: staleBeside.path)
        let explicit = await run(["mask", "--out", outDir.appendingPathComponent("new.png").path, fx.url.path])
        XCTAssertEqual(explicit.code, 0, explicit.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleBeside.path),
                      "an --out folder is never swept")
    }

    /// CS-18: a symlink planted at $TMPDIR/cheapshot-masked is refused before any sweep, so
    /// old files in the folder it points at survive and nothing is written or allowed.
    func testPlantedSymlinkForTheDefaultFolderIsRefused() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let elsewhere = tmp.appendingPathComponent("someone-elses")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let victim = elsewhere.appendingPathComponent("old-photo.png")
        try Data("v".utf8).write(to: victim)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: victim.path)
        try FileManager.default.createSymbolicLink(atPath: tmp.appendingPathComponent("cheapshot-masked").path,
                                                   withDestinationPath: elsewhere.path)

        let r = await run(["mask", fx.url.path])
        XCTAssertEqual(r.code, 1, r.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "the link's folder is never swept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["old-photo.png"],
                       "nothing is written through the link")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cheapshot-allow").path),
                       "a refused mask allows nothing")
    }

    /// CS-18: an existing default folder with a looser mode is refused, and the error names the
    /// folder and the exact command that fixes it. Nothing is swept, written or allowed.
    func testLooseDefaultFolderIsRefusedWithFix() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let maskedDir = tmp.appendingPathComponent("cheapshot-masked")
        try FileManager.default.createDirectory(at: maskedDir, withIntermediateDirectories: true)
        chmod(maskedDir.path, 0o755)
        let old = maskedDir.appendingPathComponent("old-masked.png")
        try Data("o".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: old.path)

        let r = await run(["mask", fx.url.path])
        XCTAssertEqual(r.code, 1, r.out)
        XCTAssertTrue(r.err.contains("has mode 755"), r.err)
        XCTAssertTrue(r.err.contains("chmod 700 '\(maskedDir.path)'"), r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "a refused folder is not swept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: maskedDir.path), ["old-masked.png"],
                       "nothing is written into a refused folder")

        let j = await run(["mask", "--json", fx.url.path])
        XCTAssertEqual(j.code, 1, j.out)
        XCTAssertTrue(j.out.contains("chmod 700"), "the --json error object carries the fix too: \(j.out)")

        // After the fix the same run works.
        chmod(maskedDir.path, 0o700)
        let fixed = await run(["mask", fx.url.path])
        XCTAssertEqual(fixed.code, 0, fixed.err)
    }

    /// CS-18: a $TMPDIR that does not exist yet is created, as before ensurePrivateDir, and the
    /// default folder inside it still ends up 0700.
    func testMissingTmpdirIsCreated() async throws {
        let fx = try makeFixture(lines: ["call " + Self.fakePhone])
        let missing = tmp.appendingPathComponent("not-yet/deeper")
        let r = await run(["mask", fx.url.path], tmpdir: missing.path)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(mode(missing.appendingPathComponent("cheapshot-masked").path), 0o700)
    }

    func testUsageErrors() async throws {
        for args in [["mask"], ["mask", "--raw", "a.png"], ["mask", "a.png", "b.png"],
                     ["mask", "--out", "x.jpg", "a.png"], ["mask", "--min-conf", "2", "a.png"],
                     // PR #18 review: --min-conf may only raise the floor, never lower it.
                     ["mask", "--min-conf", "0", "a.png"], ["mask", "--min-conf", "0.1", "a.png"],
                     // PR #18 second review: a control character in --out could forge allow lines.
                     ["mask", "--out", "/tmp/a\n9999999999\t/tmp/secret.png\n/tmp/y.png", "a.png"]] {
            let r = await run(args)
            XCTAssertEqual(r.code, 2, "\(args): \(r.err)")
        }
    }

    // MARK: - pure parts

    func testFlagCatchesARuleThatSpansTwoLines() {
        // A custom rule that only matches across a newline: neither line redacts on its own.
        let redactor = Redactor(rules: [Rule(name: "PAIR", pattern: #"alpha\nbravo"#, options: [])])
        let lines: [(text: String, bbox: CGRect, confidence: Float)] = [
            ("x alpha", CGRect(x: 0, y: 0, width: 10, height: 10), 1),
            ("bravo y", CGRect(x: 0, y: 20, width: 10, height: 10), 1),
            ("plain", CGRect(x: 0, y: 40, width: 10, height: 10), 1),
            ("blurry", CGRect(x: 0, y: 60, width: 10, height: 10), 0.1),
        ]
        let boxes = Masker.flag(lines, redactor: redactor, minConfidence: 0.3)
        XCTAssertEqual(boxes.map(\.reason), [.redacted, .redacted, .lowConfidence])
        XCTAssertEqual(boxes.map(\.rect.minY), [0, 20, 60])
    }

    /// Two passes see the same secret line with different extents (the layout pass stops at
    /// x 1450, the plain pass runs to 1600). Both must be painted: the whole union is black.
    func testDifferentExtentsForOneLineAreAllPainted() throws {
        let short = MaskBox(rect: CGRect(x: 100, y: 100, width: 1350, height: 40), reason: .redacted)
        let long = MaskBox(rect: CGRect(x: 100, y: 100, width: 1500, height: 40), reason: .redacted)
        let inner = MaskBox(rect: CGRect(x: 200, y: 105, width: 300, height: 30), reason: .redacted)
        let kept = Masker.dedupe([short, long, inner])
        XCTAssertTrue(kept.contains(long), "the wider box must never be dropped: \(kept)")
        XCTAssertFalse(kept.contains(inner), "only a fully contained box may be dropped")

        // A white 1800x300 canvas, painted with what dedupe kept, saved as PNG and sampled.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1800, height: 300))
        let white = try XCTUnwrap(ctx.makeImage())
        let out = tmp.appendingPathComponent("union.png")
        try Masker.pngData(try Masker.paint(white, boxes: kept)).write(to: out)
        let p = try pixels(out)
        XCTAssertEqual(blackFraction(p, in: short.rect.union(long.rect)), 1.0, accuracy: 0.0001)
        // And nothing past the padded union is painted.
        XCTAssertEqual(blackFraction(p, in: CGRect(x: 1620, y: 100, width: 100, height: 40)), 0)
    }

    func testPaddingAndClipping() {
        let r = Masker.painted(CGRect(x: 1, y: 1, width: 50, height: 40), width: 100, height: 100)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 59, height: 49))   // pad 8 = 40 * 0.2, clipped at 0
    }
}

// MARK: - CHE-24: a blank OCR read on a screenshot-like image fails closed
//
// Self-contained on purpose (helpers included) so it merges cleanly beside other MaskTests work.
extension MaskTests {
    /// A plain white canvas, no text anywhere: the blank-image fixture. The size picks the branch
    /// under test: 200 x 200 or more with one flat colour is screenshot-like (`OCR.isScreenshotLike`),
    /// anything under 200 px on a side is not.
    func makeBlankFixture(width: Int, height: Int, name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try XCTUnwrap(ctx.makeImage())
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    var allowURL: URL { tmp.appendingPathComponent("cheapshot-allow") }

    /// Files mask's default output folder holds ($TMPDIR/cheapshot-masked), empty if it does not exist.
    func defaultMaskFolderContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("cheapshot-masked").path)) ?? []
    }

    /// The sentence both failure tests expect on stderr; kept loose enough to survive rewording
    /// of the tail but specific enough that an unrelated failure does not pass.
    static let blankMessage = "looks like a screenshot"

    /// Default output path, plain text: no copy in the scratch folder, no allow file at all,
    /// non-zero exit, the reason on stderr and nothing on stdout. On the old code this image was
    /// masked with zero boxes, so the "masked" copy was the original and it was allowed for Read.
    func testBlankScreenshotLikeImageFailsClosed() async throws {
        let blank = try makeBlankFixture(width: 480, height: 360, name: "blank-shot.png")
        XCTAssertTrue(OCR.isScreenshotLike(try Masker.loadPixels(path: blank.path)),
                      "the fixture must be screenshot-like or this test proves nothing")
        let r = await run(["mask", blank.path])
        XCTAssertEqual(r.code, 1, "blank screenshot-like input must fail closed: \(r.out)")
        XCTAssertTrue(r.err.hasPrefix("cheapshot: "), r.err)
        XCTAssertTrue(r.err.contains(Self.blankMessage), r.err)
        XCTAssertTrue(r.err.contains("cheapshot allow"), "the refusal names the way out: \(r.err)")
        XCTAssertEqual(r.out, "", "nothing may claim a masked copy")
        XCTAssertEqual(defaultMaskFolderContents(), [], "no copy may be written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: allowURL.path), "no allow entry may be written")
    }

    /// --json with an explicit --out: the same error object the other mask failures emit
    /// (version, file, error and nothing else), no file at --out, no allow entry.
    func testBlankScreenshotLikeImageFailsClosedWithJSON() async throws {
        let blank = try makeBlankFixture(width: 480, height: 360, name: "blank-json.png")
        let out = tmp.appendingPathComponent("blank-masked.png")
        let r = await run(["mask", "--json", "--out", out.path, blank.path])
        XCTAssertEqual(r.code, 1, r.out)
        XCTAssertTrue(r.err.contains(Self.blankMessage), r.err)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any], r.out)
        XCTAssertEqual(j["file"] as? String, blank.path)
        XCTAssertTrue((j["error"] as? String)?.contains(Self.blankMessage) == true, "\(j)")
        XCTAssertNil(j["masked"], "no masked path may be reported: \(j)")

        // Same shape as another mask failure (a missing file goes through the same fail()).
        let missing = await run(["mask", "--json", tmp.appendingPathComponent("nope.png").path])
        let m = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(missing.out.utf8)) as? [String: Any])
        XCTAssertEqual(Set(j.keys), Set(m.keys), "blank-read error must match the other mask errors")

        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no copy may be written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: allowURL.path), "no allow entry may be written")
    }

    /// A blank image below the screenshot heuristic's size floor keeps today's behaviour: masked
    /// like a photo with no text, exit 0, copy written and allowed. Only screenshot-like blanks are gated.
    func testBlankSmallImageKeepsTheOldPath() async throws {
        let blank = try makeBlankFixture(width: 100, height: 100, name: "blank-small.png")
        XCTAssertFalse(OCR.isScreenshotLike(try Masker.loadPixels(path: blank.path)))
        let out = tmp.appendingPathComponent("small-masked.png")
        let r = await run(["mask", "--out", out.path, blank.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let allow = (try? String(contentsOf: allowURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(allow.contains(out.path), allow)
    }
}

// MARK: - CHE-24 review: faint text under the floor is masked, not refused
extension MaskTests {
    /// A 900 x 300 white canvas with `lines` drawn in light grey: Vision reads the words, but
    /// every line comes back under a high confidence floor. White dominates, so it stays screenshot-like.
    func makeFaintFixture(lines: [String], grey: CGFloat, name: String) throws -> URL {
        let w = 900, h = 300
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for (i, s) in lines.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                  kCTForegroundColorAttributeName as NSAttributedString.Key:
                                                                    CGColor(red: grey, green: grey, blue: grey, alpha: 1)])
            ctx.textPosition = CGPoint(x: 30, y: CGFloat(h) - CGFloat(60 + i * 50))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        let img = try XCTUnwrap(ctx.makeImage())
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Faint text only, every line under --min-conf 0.99: the checked read keeps no line, but
    /// Vision did see text, so this is not a blank read. Before the fix mask refused it with
    /// "OCR found no text"; it must write a masked copy with each faint line painted as
    /// low-confidence, and allow that copy.
    func testFaintTextUnderAHighFloorIsMaskedNotRefused() async throws {
        let lines = ["qzx7 Kp0w vrrt", "Jh8l mmq3 Zx"]          // nonsense, so Vision is unsure of it
        let url = try makeFaintFixture(lines: lines, grey: 0.95, name: "faint-shot.png")
        let img = try Masker.loadPixels(path: url.path)
        // The preconditions that make this the regression case, or the test proves nothing.
        XCTAssertTrue(OCR.isScreenshotLike(img))
        XCTAssertFalse(try OCR.recognizeLayout(image: img, minConfidence: 0).isEmpty, "Vision must see the faint text")
        XCTAssertTrue(try OCR.recognizeLayoutChecked(image: img, minConfidence: 0.99).lines.isEmpty,
                      "every line must sit under the 0.99 floor")

        let out = tmp.appendingPathComponent("faint-masked.png")
        let r = await run(["mask", "--json", "--min-conf", "0.99", "--out", out.path, url.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains(Self.blankMessage), r.err)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any], r.out)
        XCTAssertGreaterThanOrEqual(j["box_count"] as? Int ?? 0, 1, "the faint lines must be painted: \(j)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "the masked copy must be written")
        // The copy differs from the source: the faint lines are under black boxes.
        let a = try pixels(url), b = try pixels(out)
        XCTAssertGreaterThan(changed(a, b, in: CGRect(x: 0, y: 0, width: a.w, height: a.h)), 0)
        let allow = (try? String(contentsOf: allowURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(allow.contains(out.path), allow)
    }
}
