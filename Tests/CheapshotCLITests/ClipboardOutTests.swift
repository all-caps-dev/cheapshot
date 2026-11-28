import XCTest
import ImageIO
import CoreGraphics
import CoreText
@testable import CheapshotCLI
import CheapshotCore

/// `cheapshot --clipboard --clipboard-out` (CHE-86, CHE-87): the result goes back as the
/// clipboard's only item, same type as the input (Q8 A). Mutations C1 to C4 from plan 7.3.
final class ClipboardOutTests: XCTestCase {
    var tmp: URL!
    let fakeKey = "AKIAIOSFODNN7EXAMPLE"
    var secretLines: [String] { ["deploy key below", "aws \(fakeKey) ok"] }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-clipout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], clipboard: ClipboardSource?) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { "" },
                       environment: ["CHEAPSHOT_HOME": tmp.path], home: tmp.path, clipboard: clipboard)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func png(lines: [String], width: Int = 1400, height: Int = 400) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 36, nil)
        for (i, s) in lines.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) - CGFloat(80 + i * 70))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        let img = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func textPDF(_ text: String) throws -> URL {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// The chunk types of a PNG, in order. Fails the test on a malformed file.
    func chunkTypes(_ png: Data) throws -> [String] {
        let b = [UInt8](png)
        XCTAssertTrue(b.count >= 8 && b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "not a PNG")
        var types: [String] = [], i = 8
        while i + 12 <= b.count {
            let length = b[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: b[i + 4..<i + 8], as: UTF8.self))
            i += 12 + length
        }
        XCTAssertEqual(i, b.count, "trailing or truncated chunk")
        return types
    }

    /// The image chunks a masked copy may carry: header, pixels, end, and colour information.
    let allowedChunks: Set<String> = ["IHDR", "IDAT", "IEND", "sRGB", "iCCP", "gAMA", "cHRM", "pHYs"]

    func assertSafeMaskedPNG(_ payload: ClipboardPayload?, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .png(let data)? = payload else { return XCTFail("expected one PNG write, got \(String(describing: payload))", file: file, line: line) }
        let types = try chunkTypes(data)
        XCTAssertTrue(Set(types).isSubset(of: allowedChunks), "unexpected chunks \(types)", file: file, line: line)
        // Read the written pixels back with redaction OFF: the key must be gone from the pixels.
        let reread = try Pipeline.readImage(data: data, redaction: .raw, minConfidence: 0)
        XCTAssertFalse(reread.text.contains(fakeKey), "the key is still readable in the masked copy", file: file, line: line)
        XCTAssertFalse(reread.text.contains("AKIA"), file: file, line: line)
    }

    // MARK: - image in, masked image out (CHE-87)

    func testImageBytesGoBackAsOneMaskedPNG() async throws {
        let clip = FakeClipboard(image: try png(lines: secretLines))
        let r = await run(["--clipboard", "--clipboard-out", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(clip.writes.count, 1)
        try assertSafeMaskedPNG(clip.writes.first)
        XCTAssertNil(clip.text, "the only item is the PNG")
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["clipboard_out"] as? String, "image")
        XCTAssertTrue(r.err.contains("the masked image"), r.err)
        XCTAssertFalse(r.out.contains(fakeKey) || r.err.contains(fakeKey))
    }

    func testCopiedImageFileGoesBackAsOneMaskedPNG() async throws {
        let file = tmp.appendingPathComponent("shot.png")
        try png(lines: secretLines).write(to: file)
        let original = try Data(contentsOf: file)
        let clip = FakeClipboard(fileURLs: [file])
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(clip.writes.count, 1)
        try assertSafeMaskedPNG(clip.writes.first)
        XCTAssertEqual(try Data(contentsOf: file), original, "the copied file itself is never changed")
    }

    // MARK: - PDF in, redacted text out (CHE-86)

    func testCopiedPDFGoesBackAsRedactedTextOnly() async throws {
        let clip = FakeClipboard(fileURLs: [try textPDF("page text with key \(fakeKey) in it")])
        let r = await run(["--clipboard", "--clipboard-out", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(clip.writes.count, 1)
        guard case .text(let written)? = clip.writes.first else { return XCTFail("expected a text write") }
        XCTAssertTrue(written.contains("page text with key"), written)
        XCTAssertFalse(written.contains(fakeKey), "C1: the raw text must never go back")
        XCTAssertNil(clip.image)
        XCTAssertTrue(clip.fileURLs.isEmpty, "the copied file reference is replaced, not kept beside the text")
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["clipboard_out"] as? String, "text")
        XCTAssertEqual(c["text"] as? String, written, "what goes back is exactly what was printed")
    }

    // MARK: - nothing written

    func testClipboardChangedDuringTheReadWritesNothing() async throws {
        // C3: the user copies something else while OCR runs.
        let clip = FakeClipboard(image: try png(lines: secretLines))
        clip.onRead = { [unowned clip] in clip.bump() }
        let r = await run(["--clipboard", "--clipboard-out", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("clipboard changed during the read; left untouched"), r.err)
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertNotNil(try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]["error"])
    }

    func testClipboardChangedDuringAPDFReadWritesNothing() async throws {
        let clip = FakeClipboard(fileURLs: [try textPDF("plenty of readable text on this page")])
        clip.onRead = { [unowned clip] in clip.bump() }
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testBlankReadLeavesTheClipboardIdentical() async throws {
        // C4: never an empty string or a blank image on empty OCR.
        let blank = try png(lines: [], width: 120, height: 120)
        let clip = FakeClipboard(image: blank)
        let before = clip.changeCount
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertEqual(clip.image, blank)
        XCTAssertEqual(clip.changeCount, before)
    }

    func testBlankScreenshotLikeReadExits3AndWritesNothing() async throws {
        let clip = FakeClipboard(image: try png(lines: [], width: 800, height: 600))
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 3)
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testTextOnlyClipboardIsNeverReplaced() async throws {
        let clip = FakeClipboard(text: "hunter2")
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertEqual(clip.text, "hunter2")
    }

    func testTwoCopiedFilesAreRefusedAndNothingIsWritten() async throws {
        let a = tmp.appendingPathComponent("a.png"), b = tmp.appendingPathComponent("b.png")
        try png(lines: secretLines).write(to: a)
        try png(lines: secretLines).write(to: b)
        let clip = FakeClipboard(image: try png(lines: secretLines), fileURLs: [a, b])
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("more than one file"), r.err)
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertEqual(clip.imageReads, 0, "the Finder icon is never read")
    }

    func testOneGoneAndOneLiveFileAreRefusedAndNothingIsWritten() async throws {
        let a = tmp.appendingPathComponent("a.png")
        try png(lines: secretLines).write(to: a)
        let clip = FakeClipboard(fileURLs: [a])
        clip.unresolvableFileItems = 1
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testOneGoneFileIsReportedAndNothingIsWritten() async throws {
        let clip = FakeClipboard(image: try png(lines: secretLines))
        clip.unresolvableFileItems = 1
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("can no longer be found"), r.err)
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertEqual(clip.imageReads, 0)
    }

    func testFailedWriteExits1() async throws {
        let clip = FakeClipboard(fileURLs: [try textPDF("plenty of readable text on this page")])
        clip.failWrites = true
        let r = await run(["--clipboard", "--clipboard-out"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("could not write the clipboard"), r.err)
        XCTAssertEqual(r.out, "", "no success output after a failed write")
    }

    func testWithoutTheFlagNothingIsWritten() async throws {
        let clip = FakeClipboard(image: try png(lines: secretLines))
        let r = await run(["--clipboard"], clipboard: clip)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(clip.writes.isEmpty)
    }

    // MARK: - usage

    func testUsageErrors() async throws {
        for args in [["--clipboard-out"], ["--clipboard-out", "a.png"], ["--clipboard", "--clipboard-out", "--min-conf", "0.1"],
                     ["--clipboard", "--clipboard-out", "--raw"]] {
            let clip = FakeClipboard(image: try png(lines: secretLines))
            let r = await run(args, clipboard: clip)
            XCTAssertEqual(r.code, 2, "\(args): \(r.err)")
            XCTAssertEqual(clip.reads, 0)
            XCTAssertTrue(clip.writes.isEmpty)
        }
    }

    func testMinConfCanBeRaised() throws {
        let o = try Options.parse(["--clipboard", "--clipboard-out", "--min-conf", "0.6"])
        XCTAssertTrue(o.clipboardOut)
        XCTAssertEqual(o.minConfidence, 0.6)
        // Without --clipboard-out the read-only mode keeps the file-read floor rules.
        XCTAssertNoThrow(try Options.parse(["--clipboard", "--min-conf", "0.1"]))
    }

    func testHelpMentionsClipboardOut() {
        XCTAssertTrue(Output.usage().contains("--clipboard-out"))
    }
}
