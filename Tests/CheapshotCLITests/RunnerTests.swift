import XCTest
import ImageIO
import CoreGraphics
import CoreText
import PDFKit
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

    /// Every ledger line this run wrote, in order.
    func ledgerEntries() throws -> [[String: Any]] {
        let url = tmp.appendingPathComponent("ledger.jsonl")
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try body.split(separator: "\n").map { try json(String($0)) }
    }

    /// A one-page PDF with a real text layer, so it takes the text lane.
    func makeTextPDF(name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attr = NSAttributedString(string: "a page with plenty of readable text on it",
                                      attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// A blank white PNG: a real image input with no text in it.
    func makeBlankPNG(name: String) throws -> URL {
        let png = tmp.appendingPathComponent(name)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        return png
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
        XCTAssertEqual(try ledgerEntries().map { $0["mode"] as? String }, ["image"])
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

    /// `lines[]` has to be the same redaction `text` is, split back into lines. Redacting each
    /// line in isolation let a rule whose pattern crossed a newline redact the document but not
    /// the array (the token came back in the clear) and changed the line count, so the numbers
    /// stopped matching `text`.
    func testLineJSONMatchesTheDocumentRedactionLineForLine() throws {
        let texts = ["Authorization: Bearer", "abcdef0123456789abcdef", "key AKIAIOSFODNN7EXAMPLE"]
        let lines = texts.enumerated().map {
            RenderedLine(n: $0.offset + 1, text: $0.element,
                         bbox: CGRect(x: 0, y: CGFloat($0.offset * 16), width: 100, height: 16),
                         confidence: 1, fenced: false)
        }
        let redactor = Redactor()
        let document = redactor.redact(texts.joined(separator: "\n")).text
        let out = CLI.lineJSON(lines, redactor: redactor)
        XCTAssertEqual(out.count, texts.count)
        XCTAssertEqual(out.map { $0["n"] as? Int }, [1, 2, 3])
        XCTAssertEqual(out.map { $0["text"] as? String }, document.components(separatedBy: "\n"),
                       "lines[] must equal the document redaction split on newlines")
    }

    /// A custom rule may legitimately contain `\s`, and then the joined redaction comes back with
    /// fewer lines than it started with. Falling back to per-line redaction there keeps `n` and
    /// the boxes honest rather than silently re-numbering the array.
    func testLineJSONFallsBackWhenACustomRuleEatsANewline() throws {
        let redactor = Redactor(rules: [Rule(name: "span", pattern: #"TOKEN:\s+\S+"#)])
        XCTAssertEqual(redactor.redact("TOKEN:\nabc123").text, "[span]", "the fixture rule really does span lines")
        let lines = [RenderedLine(n: 1, text: "TOKEN:", bbox: CGRect(x: 0, y: 0, width: 50, height: 16), confidence: 1, fenced: false),
                     RenderedLine(n: 2, text: "abc123", bbox: CGRect(x: 0, y: 16, width: 50, height: 16), confidence: 1, fenced: false)]
        let out = CLI.lineJSON(lines, redactor: redactor)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(out.map { $0["text"] as? String }, ["TOKEN:", "abc123"])
        XCTAssertEqual(out[1]["bbox"] as? [Int], [0, 16, 50, 32])
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
        // The page size in --json is the rendered pixel size, so a downstream tool can scale a
        // scan-lane box against it. 612x792 points at 2x is 1224x1584.
        XCTAssertEqual(pages[0]["width"] as? Int, 1224)
        XCTAssertEqual(pages[0]["height"] as? Int, 1584)
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

    /// A locked PDF used to exit 0 with an empty text payload and a fabricated saving in the
    /// ledger. It is an input failure: an error entry, exit 1, and no ledger line at all.
    func testPasswordProtectedPDFIsAnErrorEntryAndWritesNoLedgerLine() async throws {
        let plain = tmp.appendingPathComponent("plain.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(plain as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attr = NSAttributedString(string: "a page with plenty of readable text on it",
                                      attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        let locked = tmp.appendingPathComponent("locked.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: plain))
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "x"]))

        let r = await run(["--json", "--stats", locked.path])
        XCTAssertEqual(r.code, 1, r.out)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["file"] as? String, locked.path)
        XCTAssertTrue((try XCTUnwrap(results[0]["error"] as? String)).contains("password-protected"), "\(results[0])")
        XCTAssertNil(results[0]["text"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path),
                       "a locked PDF must not record a saving")
    }

    /// The spec calls the PDF per-page number an estimate, not a measured saving, so PDFs cannot
    /// share the "image" mode with screenshots. One entry per kind present, in that order.
    func testPDFRunRecordsModePDFAndAMixedRunWritesBothModes() async throws {
        let pdf = try makeTextPDF(name: "doc.pdf")
        let r = await run([pdf.path])
        XCTAssertEqual(r.code, 0, r.err)
        var entries = try ledgerEntries()
        XCTAssertEqual(entries.map { $0["mode"] as? String }, ["pdf"])
        XCTAssertEqual(entries[0]["inputs"] as? Int, 1)

        let png = try makeBlankPNG(name: "blank.png")
        let m = await run([pdf.path, png.path])
        XCTAssertEqual(m.code, 0, m.err)
        entries = try ledgerEntries()
        XCTAssertEqual(entries.map { $0["mode"] as? String }, ["pdf", "pdf", "image"], "a mixed run writes one line per kind")
        XCTAssertEqual(entries[1]["inputs"] as? Int, 1)
        XCTAssertEqual(entries[2]["inputs"] as? Int, 1)
        XCTAssertEqual(entries[2]["image_tokens"] as? Int, 27, "the image line carries only the PNG")
        XCTAssertEqual(entries[1]["image_tokens"] as? Int, Tokens.image(width: 1224, height: 1584))
    }

    /// Output.json used to swallow a serialization failure and print `{}` with exit 0. The
    /// runner's payload has to be a valid JSON object end to end (bbox ints, finite confidence),
    /// and Output.json now refuses anything else loudly instead of emitting an empty object.
    func testRunnerPayloadIsAValidJSONObjectAndOutputRefusesAnInvalidOne() throws {
        let line = RenderedLine(n: 1, text: "x", bbox: CGRect(x: 1.2, y: 2.4, width: 3, height: 4), confidence: 0.5, fenced: false)
        let payload = CLI.payload([["file": "a.png", "lines": CLI.lineJSON([line], redactor: nil)]], imageTokens: 1, textTokens: 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertTrue(Output.json(payload).contains("\"a.png\""))
        XCTAssertFalse(Output.isValid(["nan": Double.nan]), "a non-finite number is not serializable and must not become {}")
        XCTAssertFalse(Output.isValid(["date": Date()]))
    }

    /// --newest on a directory that cannot be read used to say "no input images" and exit 2, as
    /// if the arguments were wrong. The directory is the failing input: name it, say it could not
    /// be read, exit 1.
    func testNewestOnMissingDirectoryNamesItAndExit1() async {
        let dir = tmp.appendingPathComponent("nope").path
        let r = await run(["--newest", dir])
        XCTAssertEqual(r.code, 1, r.err)
        XCTAssertTrue(r.err.contains(dir), r.err)
        XCTAssertTrue(r.err.contains("cannot read directory"), r.err)
        XCTAssertFalse(r.err.contains("no input images"), r.err)
    }

    /// An empty --newest folder is a readable input with nothing in it, not a usage error: the
    /// arguments were fine. Exit 1 like every other failed input, and name the folder.
    func testNewestOnEmptyDirectoryNamesItAndExit1() async throws {
        let dir = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = await run(["--newest", dir.path])
        XCTAssertEqual(r.code, 1, r.err)
        XCTAssertTrue(r.err.contains("no input images in \(dir.path)"), r.err)
    }

    /// --rules was loaded before the command was dispatched, so --ledger and --version failed on
    /// a bad rules file they never use. Those commands run without touching the redactor.
    func testLedgerAndVersionIgnoreABadRulesFile() async throws {
        let l = await run(["--ledger", "--json", "--rules", "/nonexistent.json"])
        XCTAssertEqual(l.code, 0, l.err)
        XCTAssertEqual(try json(l.out)["runs"] as? Int, 0)
        let v = await run(["--version", "--rules", "/nonexistent.json"])
        XCTAssertEqual(v.code, 0, v.err)
        XCTAssertEqual(v.out, cheapshotVersionForTests + "\n")
    }

    /// --pages was only read by the PDF branch, so `cheapshot --pages 1-2 shot.png` accepted the
    /// flag and ignored it. A page range on a non-PDF input is a usage error.
    func testPagesWithAnImageInputIsAUsageError() async throws {
        let png = try makeBlankPNG(name: "blank.png")
        let r = await run(["--pages", "1-2", png.path])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertTrue(r.err.contains("--pages"), r.err)
        XCTAssertTrue(r.err.contains(png.path), r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path))
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
