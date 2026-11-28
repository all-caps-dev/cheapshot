import XCTest
import ImageIO
import CoreGraphics
import CoreText
@testable import CheapshotCLI
import CheapshotCore

/// `cheapshot --clipboard` read mode (NOV-155, CHE-85), driven through `FakeClipboard`.
final class ClipboardModeTests: XCTestCase {
    var tmp: URL!
    /// A fake key the built-in AWS rule catches. It must never reach stdout, stderr or the clipboard.
    let fakeKey = "AKIAIOSFODNN7EXAMPLE"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-clip-\(UUID().uuidString)")
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

    func ledgerEntries() throws -> [[String: Any]] {
        let url = tmp.appendingPathComponent("ledger.jsonl")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try body.split(separator: "\n").map { try json(String($0)) }
    }

    /// PNG bytes of dark text on white, one line per string. `lines: []` is a blank image.
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

    var secretLines: [String] { ["deploy key below", "aws \(fakeKey) ok"] }

    // MARK: - reads

    func testImageBytesReadRedactedAndLeaveTheClipboardAlone() async throws {
        let clip = FakeClipboard(image: try png(lines: secretLines))
        let before = clip.changeCount
        let r = await run(["--clipboard"], clipboard: clip)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("deploy key below"), r.out)
        XCTAssertFalse(r.out.contains(fakeKey))
        XCTAssertFalse(r.err.contains(fakeKey))
        XCTAssertTrue(clip.writes.isEmpty, "read mode never writes the clipboard")
        XCTAssertEqual(clip.changeCount, before)
    }

    func testSameTextCountsAndLedgerAsAFileRead() async throws {
        let bytes = try png(lines: secretLines)
        let file = tmp.appendingPathComponent("shot.png")
        try bytes.write(to: file)

        let fromFile = await run([file.path, "--json"], clipboard: nil)
        XCTAssertEqual(fromFile.code, 0, fromFile.err)
        let fileLedger = try ledgerEntries()
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("ledger.jsonl"))

        let fromClip = await run(["--clipboard", "--json"], clipboard: FakeClipboard(image: bytes))
        XCTAssertEqual(fromClip.code, 0, fromClip.err)
        let clipLedger = try ledgerEntries()

        let f = try XCTUnwrap(try json(fromFile.out)["results"] as? [[String: Any]])[0]
        let c = try XCTUnwrap(try json(fromClip.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["file"] as? String, "clipboard")
        XCTAssertEqual(c["source"] as? String, "image")
        for key in ["text", "ocr_status"] { XCTAssertEqual(c[key] as? String, f[key] as? String, key) }
        for key in ["image_tokens", "text_tokens"] { XCTAssertEqual(c[key] as? Int, f[key] as? Int, key) }
        XCTAssertEqual(c["redactions"] as? [String: Int], f["redactions"] as? [String: Int])
        XCTAssertEqual((c["lines"] as? [Any])?.count, (f["lines"] as? [Any])?.count)
        XCTAssertGreaterThan((c["redactions"] as? [String: Int])?.values.reduce(0, +) ?? 0, 0)
        XCTAssertFalse(fromClip.out.contains(fakeKey))

        // The same ledger line, apart from the time it was written.
        func strip(_ e: [[String: Any]]) -> [[String: String]] {
            e.map { $0.filter { $0.key != "ts" && $0.key != "time" }.mapValues { "\($0)" } }
        }
        XCTAssertEqual(clipLedger.count, 1)
        XCTAssertEqual(strip(clipLedger), strip(fileLedger))
    }

    func testCopiedFileReadsLikeTheFileAndNeverPrintsItsPath() async throws {
        let file = tmp.appendingPathComponent("copied-in-finder.png")
        try png(lines: secretLines).write(to: file)
        let r = await run(["--clipboard", "--json"], clipboard: FakeClipboard(fileURLs: [file]))
        XCTAssertEqual(r.code, 0, r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["file"] as? String, "clipboard")
        XCTAssertEqual(c["source"] as? String, "file_url")
        XCTAssertTrue((c["text"] as? String ?? "").contains("deploy key below"))
        XCTAssertFalse(r.out.contains("copied-in-finder"))
        XCTAssertFalse(r.out.contains(fakeKey))
    }

    func testCopiedPDFReadsWithoutItsPath() async throws {
        let url = tmp.appendingPathComponent("private-name.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
            string: "page text with key \(fakeKey) in it",
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])), ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        let r = await run(["--clipboard", "--json"], clipboard: FakeClipboard(fileURLs: [url]))
        XCTAssertEqual(r.code, 0, r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["source"] as? String, "file_url")
        let doc = try XCTUnwrap(c["document"] as? [String: Any])
        XCTAssertEqual(doc["pages"] as? Int, 1)
        XCTAssertNil(doc["path"])
        XCTAssertFalse(r.out.contains("private-name"))
        XCTAssertFalse(r.out.contains(fakeKey))
        XCTAssertEqual(try ledgerEntries().first?["mode"] as? String, "pdf")
    }

    func testCopiedFileWinsOverTheIconImageFinderAlsoPuts() async throws {
        let file = tmp.appendingPathComponent("real.png")
        try png(lines: secretLines).write(to: file)
        let icon = try png(lines: [], width: 120, height: 120)   // blank: reading it would exit 1
        let r = await run(["--clipboard", "--json"], clipboard: FakeClipboard(image: icon, fileURLs: [file]))
        XCTAssertEqual(r.code, 0, r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["source"] as? String, "file_url")
        XCTAssertTrue((c["text"] as? String ?? "").contains("deploy key below"))
    }

    func testTwoCopiedFilesExit1AndNeverReadTheIcon() async throws {
        let a = tmp.appendingPathComponent("first-secret.png"), b = tmp.appendingPathComponent("second-secret.png")
        try png(lines: secretLines).write(to: a)
        try png(lines: secretLines).write(to: b)
        let icon = try png(lines: secretLines)   // would read as text if the icon were OCRed
        let clip = FakeClipboard(image: icon, fileURLs: [a, b])
        let r = await run(["--clipboard", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 1, r.err)
        XCTAssertTrue(r.err.contains("more than one file"), r.err)
        XCTAssertEqual(clip.imageReads, 0, "the Finder icon must never be read")
        XCTAssertFalse(r.out.contains("first-secret") || r.err.contains("first-secret"))
        XCTAssertFalse(r.out.contains("deploy key below"))
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertTrue(try ledgerEntries().isEmpty)
    }

    func testBlankCopiedPDFExits1() async throws {
        let url = tmp.appendingPathComponent("blank.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let r = await run(["--clipboard", "--json"], clipboard: FakeClipboard(fileURLs: [url]))
        XCTAssertEqual(r.code, 1, r.err)
        XCTAssertTrue(r.err.contains("no text found in the PDF"), r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertNotNil(c["error"])
    }

    // MARK: - nothing usable: exit 1, clipboard untouched, nothing from it printed

    func testTextOnlyClipboardIsRefusedAndNeverEchoed() async throws {
        let clip = FakeClipboard(text: "hunter2 \(fakeKey)")
        for args in [["--clipboard"], ["--clipboard", "--json"]] {
            let r = await run(args, clipboard: clip)
            XCTAssertEqual(r.code, 1, args.joined(separator: " "))
            XCTAssertTrue(r.err.contains("no image on the clipboard"), r.err)
            XCTAssertFalse(r.out.contains("hunter2") || r.err.contains("hunter2"))
            XCTAssertFalse(r.out.contains(fakeKey) || r.err.contains(fakeKey))
        }
        XCTAssertTrue(clip.writes.isEmpty)
        XCTAssertEqual(clip.text, "hunter2 \(fakeKey)")
        XCTAssertTrue(try ledgerEntries().isEmpty)
    }

    func testEmptyClipboardExits1() async throws {
        let r = await run(["--clipboard", "--json"], clipboard: FakeClipboard())
        XCTAssertEqual(r.code, 1)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["file"] as? String, "clipboard")
        XCTAssertNotNil(c["error"])
    }

    func testUnreadableBytesExit1() async throws {
        let clip = FakeClipboard(image: Data("not an image \(fakeKey)".utf8))
        let r = await run(["--clipboard"], clipboard: clip)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("cannot read the image on the clipboard"), r.err)
        XCTAssertFalse(r.err.contains(fakeKey))
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testCopiedFileThatIsGoneExits1WithoutItsPath() async throws {
        let gone = tmp.appendingPathComponent("secret-project-name.png")
        let r = await run(["--clipboard"], clipboard: FakeClipboard(fileURLs: [gone]))
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("no longer exists"), r.err)
        XCTAssertFalse(r.err.contains("secret-project-name"))
    }

    func testCopiedFolderExits1() async throws {
        let r = await run(["--clipboard"], clipboard: FakeClipboard(fileURLs: [tmp]))
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("folder"), r.err)
    }

    func testNoClipboardOnThisPlatformExits1() async throws {
        let r = await run(["--clipboard"], clipboard: nil)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("not supported on this platform"), r.err)
    }

    // MARK: - blank text: stricter than a file read

    func testBlankSmallImageExits1() async throws {
        // Under 200 px is never screenshot-like, so there is no retry: a plain blank, exit 1.
        let clip = FakeClipboard(image: try png(lines: [], width: 120, height: 120))
        let r = await run(["--clipboard", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 1, r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["ocr_status"] as? String, "empty")
        XCTAssertEqual(c["retried"] as? Bool, false)
        XCTAssertNotNil(c["error"])
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testBlankScreenshotLikeImageExits3AfterARetry() async throws {
        // A big flat image is screenshot-like; blank after the retry is the cold-start case.
        let clip = FakeClipboard(image: try png(lines: [], width: 800, height: 600))
        let r = await run(["--clipboard", "--json"], clipboard: clip)
        XCTAssertEqual(r.code, 3, r.err)
        let c = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])[0]
        XCTAssertEqual(c["retried"] as? Bool, true)
        XCTAssertTrue(r.err.contains("after a retry"), r.err)
        XCTAssertTrue(clip.writes.isEmpty)
    }

    func testBlankTextModeWritesNothingToStdout() async throws {
        let r = await run(["--clipboard"], clipboard: FakeClipboard(image: try png(lines: [], width: 120, height: 120)))
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.out, "")
    }

    // MARK: - usage errors (mutation C5: --raw must never be accepted)

    func testCombinationsAreUsageErrors() async throws {
        let file = tmp.appendingPathComponent("a.png")
        try png(lines: ["x"]).write(to: file)
        let bad: [[String]] = [
            ["--clipboard", "--raw"],
            ["--raw", "--clipboard"],
            ["--clipboard", file.path],
            ["--clipboard", "--", file.path],
            ["--clipboard", "--pages", "1"],
            ["--clipboard", "--newest"],
            ["--clipboard", "--cleanshot"],
            ["--clipboard", "--text", "-"],
            ["--clipboard", "--video", file.path],
            ["--clipboard", "--ledger"],
            ["--clipboard", "--days", "3"],
            ["--clipboard", "--frames-at", "1"],
        ]
        for args in bad {
            let clip = FakeClipboard(image: try png(lines: secretLines))
            let r = await run(args, clipboard: clip)
            XCTAssertEqual(r.code, 2, "\(args): \(r.err)")
            XCTAssertEqual(clip.reads, 0, "\(args): a usage error must not read the clipboard")
        }
    }

    func testParserRefusesRawWithClipboard() {
        // The parser is the gate (mutation C5); the runner's nil-redactor check is only a backstop.
        for args in [["--clipboard", "--raw"], ["--raw", "--clipboard"]] {
            XCTAssertThrowsError(try Options.parse(args), args.joined(separator: " "))
        }
    }

    func testParseGivesTheClipboardCommandWithRedactionOn() throws {
        let o = try Options.parse(["--clipboard", "--json", "--stats", "--min-conf", "0.5", "--no-ledger"])
        XCTAssertEqual(o.command, .clipboard)
        XCTAssertTrue(o.redact)
        XCTAssertTrue(o.json && o.stats && o.noLedger)
        XCTAssertEqual(o.minConfidence, 0.5)
    }

    func testStatsAndNoLedger() async throws {
        let r = await run(["--clipboard", "--stats", "--no-ledger"], clipboard: FakeClipboard(image: try png(lines: secretLines)))
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("1 image(s)"), r.err)
        XCTAssertTrue(try ledgerEntries().isEmpty)
    }

    func testHelpMentionsClipboardAndExit3() {
        let u = Output.usage()
        XCTAssertTrue(u.contains("--clipboard"))
        XCTAssertTrue(u.contains("3 --clipboard only"))
    }
}
