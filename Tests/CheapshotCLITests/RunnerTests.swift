import XCTest
import ImageIO
import CoreGraphics
import CoreText
@testable import CheapshotCLI
import CheapshotCore

/// Captures everything the runner writes so tests never touch the real stdout or the real home.
struct Capture {
    var out = "", err = ""
    var stdin = ""
    var environment: [String: String] = [:]
    var home: String

    init(home: String) { self.home = home }
}

final class RunnerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], stdin: String = "", env: [String: String] = [:]) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        var env = env
        env["CHEAPSHOT_HOME"] = env["CHEAPSHOT_HOME"] ?? tmp.path   // never write the real ledger
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { stdin },
                       environment: env, home: tmp.path)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testMissingFileIsAnErrorEntryAndExit1() async throws {
        let r = await run(["--json", "missing.png"])
        XCTAssertEqual(r.code, 1)
        let payload = try json(r.out)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["file"] as? String, "missing.png")
        XCTAssertNotNil(results[0]["error"] as? String)
        XCTAssertEqual(payload["version"] as? String, cheapshotVersionForTests)
    }

    func testMissingFileWithoutJSONStillExit1() async {
        let r = await run(["missing.png"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("missing.png"))
    }

    func testUnknownFlagExit2() async {
        let r = await run(["--bogus"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("unknown option --bogus"))
    }

    func testMinConfWithoutValueExit2() async {
        let r = await run(["--min-conf", "shot.png"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("--min-conf"))
    }

    func testTextStdinRedactsWithContextCueOnly() async {
        let r = await run(["--text", "-"], stdin: "acct 12345678\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "acct [BANK_ACCT]\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path), "--text must not write the ledger")
    }

    func testTextFileAndJSON() async throws {
        let f = tmp.appendingPathComponent("in.txt")
        try "key AKIAIOSFODNN7EXAMPLE".write(to: f, atomically: true, encoding: .utf8)
        let r = await run(["--text", f.path, "--json"])
        XCTAssertEqual(r.code, 0)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["text"] as? String, "key [AWS_KEY]")
        XCTAssertEqual((results[0]["redactions"] as? [String: Int])?["AWS_KEY"], 1)
        XCTAssertEqual(results[0]["image_tokens"] as? Int, 0)
    }

    func testTextRawSkipsRedaction() async {
        let r = await run(["--text", "-", "--raw"], stdin: "ryan@example.com")
        XCTAssertEqual(r.out, "ryan@example.com\n")
    }

    func testRulesFileApplies() async throws {
        let rules = tmp.appendingPathComponent("rules.json")
        try #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"}]"#.write(to: rules, atomically: true, encoding: .utf8)
        let r = await run(["--rules", rules.path, "--text", "-"], stdin: "INT-123456 ryan@example.com")
        XCTAssertEqual(r.out, "[TICKET] [EMAIL]\n")
    }

    func testBadRulesFileExit2() async {
        let r = await run(["--rules", "/nonexistent.json", "--text", "-"], stdin: "x")
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("rules"))
    }

    func testLedgerJSONOnEmptyLedger() async throws {
        let r = await run(["--ledger", "--json"])
        XCTAssertEqual(r.code, 0)
        let s = try json(r.out)
        XCTAssertEqual(s["runs"] as? Int, 0)
        XCTAssertEqual(s["saved"] as? Int, 0)
    }

    func testFailedRunWritesNoLedgerLine() async {
        _ = await run(["missing.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path))
    }

    func testLedgerMigrateReportsCount() async throws {
        let tsv = tmp.appendingPathComponent(".claude/cheapshot-ledger")
        try FileManager.default.createDirectory(at: tsv, withIntermediateDirectories: true)
        try "2026-09-08T01:05:35Z\timage\t1\t1550\t54\t1496\t10\n".write(to: tsv.appendingPathComponent("20260908.tsv"), atomically: true, encoding: .utf8)
        let r = await run(["--ledger", "--migrate"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("imported 1"), r.out)
        let again = await run(["--ledger", "--migrate"])
        XCTAssertTrue(again.out.contains("imported 0"), again.out)
    }

    /// A blank white PNG has no text. This asserts the JSON shape, not OCR content.
    func testBlankImageJSONHasLinesArrayAndTokens() async throws {
        let png = tmp.appendingPathComponent("blank.png")
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))

        let r = await run(["--json", png.path])
        XCTAssertEqual(r.code, 0, r.err)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first["file"] as? String, png.path)
        XCTAssertNotNil(first["lines"] as? [[String: Any]])
        XCTAssertEqual(first["image_tokens"] as? Int, 27)   // 200*100/750
        XCTAssertNotNil(first["text"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path), "successful run writes the ledger")
    }

    /// The JSON line array is redacted line by line and its box is integer pixels, top-left origin.
    func testLineJSONRedactsEachLineAndRoundsTheBox() throws {
        let line = RenderedLine(n: 1, text: "key AKIAIOSFODNN7EXAMPLE",
                                bbox: CGRect(x: 10.4, y: 20.6, width: 100, height: 16),
                                confidence: 0.97, fenced: false)
        let out = CLI.lineJSON([line], redactor: Redactor())
        let o = try XCTUnwrap(out.first)
        XCTAssertEqual(o["n"] as? Int, 1)
        XCTAssertEqual(o["text"] as? String, "key [AWS_KEY]")
        XCTAssertEqual(o["bbox"] as? [Int], [10, 21, 110, 37])
        XCTAssertNotNil(o["confidence"] as? Double)
    }

    /// The three --json failure paths must all produce an envelope, not just the missing-file one.
    func testJSONVideoMissingFileIsAnErrorEntryAndExit1() async throws {
        let path = tmp.appendingPathComponent("missing.mp4").path
        let r = await run(["--json", "--no-ledger", "--video", path])
        XCTAssertEqual(r.code, 1)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["file"] as? String, path)
        XCTAssertEqual(results[0]["error"] as? String, "no such video")
    }

    func testJSONVideoUnreadableFileIsAnErrorEntryAndExit1() async throws {
        try XCTSkipIf(FFmpegFrameSource.findFFmpeg() == nil, "ffmpeg not installed")
        let bad = tmp.appendingPathComponent("bad.mp4")
        try Data((0..<16).map { _ in UInt8.random(in: 0...255) }).write(to: bad)
        let r = await run(["--json", "--no-ledger", "--video", bad.path])
        XCTAssertEqual(r.code, 1)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["file"] as? String, bad.path)
        XCTAssertFalse((try XCTUnwrap(results[0]["error"] as? String)).isEmpty)
    }

    func testPDFJSONHasSourceShaAndPageLanes() async throws {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["acct 12345678 on page one", "page two has enough text to count"] {
            ctx.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let r = await run(["--pages", "1-2", url.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        let source = try XCTUnwrap(results[0]["source"] as? [String: Any])
        XCTAssertEqual((source["sha256"] as? String)?.count, 64)
        XCTAssertEqual(source["pages"] as? Int, 2)
        let pages = try XCTUnwrap(results[0]["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { $0["lane"] as? String }, ["text", "text"])
        XCTAssertEqual(pages.map { $0["n"] as? Int }, [1, 2])
        let text = try XCTUnwrap(results[0]["text"] as? String)
        XCTAssertTrue(text.contains("--- page 2 ---"))
        XCTAssertTrue(text.contains("acct [BANK_ACCT]"), text)
        let firstLine = try XCTUnwrap((pages[0]["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstLine["text"] as? String, "acct [BANK_ACCT] on page one", "lines are redacted too")
        // A 612x792 point page renders at 2x, 1224x1584; the long edge scales to 1568, so the
        // billed size is 1211.6x1568 / 750 = 2533 tokens per page, 5066 for the two.
        XCTAssertEqual(Tokens.image(width: 1224, height: 1584), 2533)
        XCTAssertEqual((results[0]["image_tokens"] as? Int), 2 * Tokens.image(width: 1224, height: 1584))
    }

    func testHelpAndVersion() async {
        let h = await run([])
        XCTAssertEqual(h.code, 0)
        XCTAssertTrue(h.out.contains("USAGE"))
        let v = await run(["--version"])
        XCTAssertEqual(v.out, cheapshotVersionForTests + "\n")
    }
}

let cheapshotVersionForTests = cheapshotVersion
