// Swift. Native app plan, step 2: the image, PDF and text pipeline moved out of the CLI into
// CheapshotCore. These tests prove the move changed no CLI output.
//
// How: every case runs twice in the same process, on the same fixture files, with the same home
// directory, once through LegacyCLI (a frozen copy of the CLI at origin/main 1c0876a, v0.6.0, with its
// NSImage loader) and once through today's CLI.run. Stdout, stderr, exit code and the ledger
// lines (minus their timestamp) must be byte-identical. Comparing inside one run means Vision's
// output can drift between macOS versions without breaking the test: both sides read the same
// pixels on the same OS.
//
// Fixtures are synthetic, drawn here with CoreText. The fake secrets are built from parts so no
// whole token sits in one literal; none is a real credential.
import XCTest
import ImageIO
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
@testable import CheapshotCLI
@testable import CheapshotCore

final class PipelineParityTests: XCTestCase {
    var tmp: URL!
    var home: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-parity-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    static let fakeKey = "AKIA" + "IOSFODNN7" + "EXAMPLE"
    static let fakeMail = "jane.doe" + "@example.com"
    static let lines = [
        "Deploy log for the staging host",
        "contact \(fakeMail) for access",
        "server 10.20.30.40 port 8443",
        "key \(fakeKey) rotated",
        "acct 12345678 billing",
    ]

    // MARK: - fixtures

    /// Text drawn black on white, one string per row, at `scale` pixels per point.
    func textImage(_ rows: [String], scale: CGFloat = 2) throws -> CGImage {
        let wPt: CGFloat = 900, rowPt: CGFloat = 50
        let w = Int(wPt * scale), h = Int((CGFloat(rows.count) * rowPt + 40) * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22 * scale, nil)
        for (i, s) in rows.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 30 * scale, y: CGFloat(h) - (CGFloat(i) * rowPt + 45) * scale)   // CG is bottom-left
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    func write(_ image: CGImage, _ name: String, _ type: UTType, _ props: [CFString: Any] = [:]) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// A @2x screenshot: 144 DPI, the way macOS writes Retina captures.
    func screenshot() throws -> String {
        try write(try textImage(Self.lines), "shot@2x.png", .png, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    }

    /// A phone-style JPEG: the pixels are stored turned a quarter, with EXIF orientation 6 to
    /// turn them back. Orientation 8's drawing is the inverse of 6's, so it makes the stored copy.
    func rotatedPhoto() throws -> String {
        let upright = try textImage(Array(Self.lines.prefix(3)))
        let stored = try XCTUnwrap(ImageLoader.upright(upright, orientation: 8))
        let path = try write(stored, "photo.jpg", .jpeg, [kCGImagePropertyOrientation: 6])
        XCTAssertEqual(ImageLoader.pixelSize(path: path)?.width, upright.width, "fixture is not stored rotated")
        return path
    }

    func blankPNG() throws -> String {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return try write(try XCTUnwrap(ctx.makeImage()), "blank.png", .png)
    }

    /// Two pages with a real text layer (the text lane), secrets on both.
    func textPDF() throws -> String {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in [Array(Self.lines.prefix(3)), Array(Self.lines.suffix(2))] {
            ctx.beginPDFPage(nil)
            for (i, s) in page.enumerated() {
                let font = CTFontCreateWithName((i == 1 ? "Menlo" : "Helvetica") as CFString, 12, nil)
                let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 20)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.path
    }

    func file(_ name: String, _ body: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - the comparison

    struct Outcome: Equatable {
        var code: Int32, out: String, err: String, ledger: [String]
    }

    /// One run through `body`, with the ledger file read back (timestamps blanked) and removed,
    /// so the next run starts from the same empty home.
    func capture(env: [String: String], stdin: String, _ body: (CLIIO) async -> Int32) async throws -> Outcome {
        final class Box { var out = "", err = "" }
        let box = Box()
        var env = env
        env["CHEAPSHOT_HOME"] = env["CHEAPSHOT_HOME"] ?? home.path
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { stdin },
                       environment: env, home: home.path, isInteractive: false)
        let code = await body(io)
        let ledgerURL = Ledger.resolveURL(environment: env, home: home.path)
        let body = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: ledgerURL)
        let ledger = body.split(separator: "\n").map {
            $0.replacingOccurrences(of: #""ts":"[^"]*""#, with: #""ts":"-""#, options: .regularExpression)
        }
        return Outcome(code: code, out: box.out, err: box.err, ledger: ledger)
    }

    /// Runs `args` through the frozen CLI and today's CLI and fails on any byte of difference.
    @discardableResult
    func assertSame(_ args: [String], env: [String: String] = [:], stdin: String = "",
                    file: StaticString = #filePath, line: UInt = #line) async throws -> Outcome {
        let before = try await capture(env: env, stdin: stdin) { LegacyCLI.run(arguments: args, io: $0) }
        let after = try await capture(env: env, stdin: stdin) { await CLI.run(arguments: args, io: $0) }
        XCTAssertEqual(after.code, before.code, "exit code for \(args)", file: file, line: line)
        XCTAssertEqual(after.out, before.out, "stdout for \(args)", file: file, line: line)
        XCTAssertEqual(after.err, before.err, "stderr for \(args)", file: file, line: line)
        XCTAssertEqual(after.ledger, before.ledger, "ledger for \(args)", file: file, line: line)
        return after
    }

    // MARK: - cases

    func testImageRunsAreByteIdentical() async throws {
        let shot = try screenshot()
        let plain = try await assertSame([shot])
        // Guard against a vacuous pass: the fixture must really be read and redacted.
        XCTAssertTrue(plain.out.contains("[EMAIL]"), plain.out)
        XCTAssertFalse(plain.out.contains(Self.fakeMail), plain.out)
        try await assertSame(["--json", shot])
        try await assertSame(["--stats", shot])
        try await assertSame(["--json", "--stats", "--no-ledger", shot])
        try await assertSame(["--min-conf", "0.9", "--json", shot])
    }

    func testRawRunsAreByteIdenticalAndMarkedRaw() async throws {
        let shot = try screenshot()
        let raw = try await assertSame(["--raw", "--json", "--stats", shot])
        XCTAssertTrue(raw.ledger.first?.contains(#""raw":true"#) ?? false, raw.ledger.description)
    }

    func testRotatedPhotoIsByteIdentical() async throws {
        let photo = try rotatedPhoto()
        let r = try await assertSame(["--json", photo])
        XCTAssertTrue(r.out.contains("[EMAIL]"), "the upright text was not read: \(r.out)")
    }

    func testPDFRunsAreByteIdentical() async throws {
        let pdf = try textPDF()
        let r = try await assertSame(["--json", pdf])
        XCTAssertTrue(r.out.contains("[BANK_ACCT]"), r.out)
        try await assertSame([pdf])
        try await assertSame(["--stats", "--pages", "2", pdf])
        try await assertSame(["--json", "--force-ocr", pdf])
        try await assertSame(["--json", "--pages", "3", pdf])
    }

    func testMixedRunWithFailuresIsByteIdentical() async throws {
        let junk = try file("junk.png", "not an image")
        let missing = tmp.appendingPathComponent("missing.png").path
        let args = [try screenshot(), try blankPNG(), try textPDF(), missing, junk]
        let r = try await assertSame(["--json", "--stats"] + args)
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.ledger.count, 2, "one pdf line and one image line")
        try await assertSame(args)
        try await assertSame(["--pages", "1"] + args)   // usage error: --pages with an image
    }

    func testNewestIsByteIdentical() async throws {
        _ = try screenshot(); _ = try blankPNG()
        try await assertSame(["--newest", tmp.path, "2", "--json"])
        try await assertSame(["--newest", tmp.appendingPathComponent("nope").path, "--json"])
        let empty = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await assertSame(["--newest", empty.path, "--json"])
    }

    func testRulesFilesAreByteIdentical() async throws {
        let shot = try screenshot(), pdf = try textPDF()
        // A rule that eats every newline, so the per-line JSON takes its fallback path.
        let newline = try file("newline.json", #"[{"name":"nl","pattern":"\\n"}]"#)
        try await assertSame(["--json", "--rules", newline, shot, pdf])
        let ticket = try file("ticket.json", #"[{"name":"host","pattern":"staging host"}]"#)
        try await assertSame(["--json", shot], env: ["CHEAPSHOT_RULES": ticket])
        try await assertSame(["--rules", tmp.appendingPathComponent("missing.json").path, shot])
        // A broken default rules.json next to the ledger warns and keeps the built-in rules.
        try "not json".write(to: home.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        let broken = try await assertSame(["--json", shot])
        XCTAssertTrue(broken.err.contains("warning: ignoring"), broken.err)
    }

    func testTextRunsAreByteIdentical() async throws {
        let input = Self.lines.joined(separator: "\n") + "\n"
        try await assertSame(["--text", "-"], stdin: input)
        try await assertSame(["--text", "-", "--json", "--stats"], stdin: input)
        try await assertSame(["--text", "-", "--raw"], stdin: input)
        try await assertSame(["--text", try file("in.txt", input + "\n"), "--json"])
        try await assertSame(["--text", tmp.appendingPathComponent("missing.txt").path, "--json"])
    }
}
