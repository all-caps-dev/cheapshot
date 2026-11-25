// Swift. Pipeline is the one place that turns an image, a PDF or a piece of text into redacted
// text, redaction counts, token counts and ledger lines. The CLI calls it, and the native app
// will call it, so both give the same answer for the same input (native app plan, step 2).
//
// These tests run on macOS and on the iOS Simulator. Fixtures are synthetic, drawn here with
// CoreText; the fake secrets are built from parts and none is a real credential.
import XCTest
import ImageIO
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
@testable import CheapshotCore

final class PipelineTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    static let fakeMail = "jane.doe" + "@example.com"
    static let rows = ["Deploy log for staging", "contact \(fakeMail) today", "acct 12345678 billing"]

    /// Black text on white, one string per row, 2 pixels per point like a Retina screenshot.
    func textImage(_ rows: [String] = PipelineTests.rows) throws -> CGImage {
        let scale: CGFloat = 2, w = 1600, rowPt: CGFloat = 50
        let h = Int((CGFloat(rows.count) * rowPt + 40) * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22 * scale, nil)
        for (i, s) in rows.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(h) - (CGFloat(i) * rowPt + 45) * scale)   // CG is bottom-left
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    func pngFile(_ image: CGImage, _ name: String = "shot.png") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func line(_ n: Int, _ text: String) -> RenderedLine {
        RenderedLine(n: n, text: text, bbox: CGRect(x: 1.4, y: 2.5, width: 10, height: 4), confidence: 0.9, fenced: false)
    }

    // MARK: - text

    func testReadTextDropsOneTrailingNewlineAndRedacts() {
        let r = Pipeline.readText("acct 12345678\n\n", redaction: .redact(Redactor()))
        XCTAssertEqual(r.text, "acct [BANK_ACCT]\n")
        XCTAssertTrue(r.redacted)
        XCTAssertEqual(r.report.counts, ["BANK_ACCT": 1])
        XCTAssertEqual(r.textTokens, Tokens.text(r.text))
    }

    func testRawIsExplicitAndEveryResultSaysSo() throws {
        // Redaction off has to be asked for by name (.raw); there is no nil that means raw.
        let r = Pipeline.readText("mail \(Self.fakeMail)", redaction: .raw)
        XCTAssertEqual(r.text, "mail \(Self.fakeMail)")
        XCTAssertEqual(r.report, RedactionReport())
        XCTAssertFalse(r.redacted)
        XCTAssertEqual(Pipeline.redact("x \(Self.fakeMail)", with: .raw).text, "x \(Self.fakeMail)")
        XCTAssertEqual(Pipeline.redactLines([line(1, Self.fakeMail)], with: .raw).map(\.text), [Self.fakeMail])
        XCTAssertFalse(Pipeline.Redaction.raw.isRedacting)
        XCTAssertTrue(Pipeline.Redaction.redact(Redactor()).isRedacting)

        let image = try Pipeline.readImage(try textImage(), redaction: .raw, minConfidence: 0.3)
        XCTAssertFalse(image.redacted)
        XCTAssertTrue(image.text.contains(Self.fakeMail), "raw means the text as read: \(image.text)")
        XCTAssertEqual(image.report, RedactionReport())
    }

    func testReadPDFRawSaysSo() throws {
        let url = tmp.appendingPathComponent("raw.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: "acct 12345678 on page one", attributes: [kCTFontAttributeName as NSAttributedString.Key:
                                                                                    CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        let r = try Pipeline.readPDF(url: url, pages: nil, minConfidence: 0.3, forceOCR: false, redaction: .raw)
        XCTAssertFalse(r.redacted)
        XCTAssertTrue(r.text.contains("12345678"), r.text)
    }

    // MARK: - per-line redaction

    func testRedactLinesMatchesTheDocumentRedactionAndKeepsGeometry() {
        let lines = [line(1, "mail \(Self.fakeMail)"), line(2, "plain")]
        let out = Pipeline.redactLines(lines, with: .redact(Redactor()))
        XCTAssertEqual(out.map(\.text), ["mail [EMAIL]", "plain"])
        XCTAssertEqual(out.map(\.n), [1, 2])
        XCTAssertEqual(out.map(\.bbox), lines.map(\.bbox))
        XCTAssertEqual(out.map(\.confidence), lines.map(\.confidence))
    }

    func testRedactLinesCatchesARuleThatNeedsTheLineAbove() {
        // Fires only with the line above in view, so per-line redaction would miss it.
        let redactor = Redactor(rules: [Rule(name: "bearer", pattern: #"(?<=Authorization: Bearer\n)\S+"#)])
        let out = Pipeline.redactLines([line(1, "Authorization: Bearer"), line(2, "abc123")], with: .redact(redactor))
        XCTAssertEqual(out.map(\.text), ["Authorization: Bearer", "[bearer]"])
    }

    func testRedactLinesFallsBackToPerLineWhenARuleEatsANewline() throws {
        let redactor = Redactor(customRules: try RuleFile.parse(Data(#"[{"name":"nl","pattern":"\\n"}]"#.utf8)))
        let out = Pipeline.redactLines([line(1, "a \(Self.fakeMail)"), line(2, "b")], with: .redact(redactor))
        XCTAssertEqual(out.map(\.text), ["a [EMAIL]", "b"], "each line on its own, still redacted")
    }

    // MARK: - images

    func testReadImageRedactsAndCountsTokens() throws {
        let image = try textImage()
        let r = try Pipeline.readImage(image, redaction: .redact(Redactor()), minConfidence: 0.3)
        XCTAssertTrue(r.redacted)
        XCTAssertTrue(r.text.contains("[EMAIL]"), r.text)
        XCTAssertTrue(r.text.contains("[BANK_ACCT]"), r.text)
        XCTAssertEqual(r.report.counts["EMAIL"], 1)
        // The raw secret is nowhere in the result: not the text, not any line.
        XCTAssertFalse(r.text.contains(Self.fakeMail))
        XCTAssertFalse(r.lines.contains { $0.text.contains(Self.fakeMail) })
        XCTAssertFalse(r.lines.isEmpty)
        for l in r.lines { XCTAssertTrue(r.text.contains(l.text), "line \(l.n) is not in the text: \(l.text)") }
        XCTAssertEqual(r.width, image.width)
        XCTAssertEqual(r.height, image.height)
        XCTAssertEqual(r.imageTokens, Tokens.image(width: image.width, height: image.height))
        XCTAssertEqual(r.textTokens, Tokens.text(r.text))
    }

    func testReadImageFromPathDataAndPixelsAgree() throws {
        let image = try textImage()
        let url = try pngFile(image)
        let a = try Pipeline.readImage(path: url.path, redaction: .redact(Redactor()), minConfidence: 0.3)
        let b = try Pipeline.readImage(data: try Data(contentsOf: url), redaction: .redact(Redactor()), minConfidence: 0.3)
        let c = try Pipeline.readImage(image, redaction: .redact(Redactor()), minConfidence: 0.3)
        for other in [b, c] {
            XCTAssertEqual(a.text, other.text)
            XCTAssertEqual(a.report, other.report)
            XCTAssertEqual(a.lines, other.lines)
            XCTAssertEqual(a.imageTokens, other.imageTokens)
        }
    }

    func testPixelSizeOverridesTheImageSizeForTokens() throws {
        let image = try textImage()
        let r = try Pipeline.readImage(image, pixelSize: (100, 50), redaction: .raw, minConfidence: 0.3)
        XCTAssertEqual(r.imageTokens, Tokens.image(width: 100, height: 50))
    }

    func testUnreadableImageThrowsCannotReadImage() throws {
        let junk = tmp.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try Pipeline.readImage(path: junk.path, redaction: .raw, minConfidence: 0.3)) { e in
            XCTAssertEqual(e as? Pipeline.ReadError, .unreadableImage)
            XCTAssertEqual("\(e)", "cannot read image")
        }
        XCTAssertThrowsError(try Pipeline.readImage(data: Data(), redaction: .raw, minConfidence: 0.3))
    }

    // MARK: - PDFs

    func testReadPDFRedactsTextAndLinesAndSumsPageTokens() throws {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["acct 12345678 on page one", "page two mails \(Self.fakeMail) now"] {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key:
                                                                        CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let r = try Pipeline.readPDF(url: url, pages: nil, minConfidence: 0.3, forceOCR: false, redaction: .redact(Redactor()))
        XCTAssertTrue(r.redacted)
        XCTAssertEqual(r.document.pageCount, 2)
        XCTAssertEqual(r.document.sha256.count, 64)
        XCTAssertTrue(r.text.contains("acct [BANK_ACCT]"), r.text)
        XCTAssertTrue(r.text.contains("[EMAIL]"), r.text)
        XCTAssertEqual(r.report.counts, ["BANK_ACCT": 1, "EMAIL": 1])
        XCTAssertEqual(r.document.pages.first?.lines.first?.text, "acct [BANK_ACCT] on page one", "page lines are redacted")
        XCTAssertFalse(r.document.pages.flatMap(\.lines).contains { $0.text.contains(Self.fakeMail) })
        XCTAssertEqual(r.imageTokens, 2 * Tokens.image(width: 1224, height: 1584))
        XCTAssertEqual(r.textTokens, Tokens.text(r.text))
    }

    // MARK: - totals and ledger lines

    func testTotalsAndLedgerEntriesOneLinePerKindPresent() {
        var pdfs = Pipeline.Totals(), images = Pipeline.Totals()
        images.add(imageTokens: 100, textTokens: 10, redactions: 2)
        images.add(imageTokens: 50, textTokens: 5, redactions: 0)
        XCTAssertEqual(images, Pipeline.Totals(inputs: 2, imageTokens: 150, textTokens: 15, redactions: 2))

        let onlyImages = Pipeline.ledgerEntries(pdfs: pdfs, images: images, redacted: true)
        XCTAssertEqual(onlyImages.map(\.mode), ["image"])
        XCTAssertEqual(onlyImages.first?.saved, 135)
        XCTAssertNil(onlyImages.first?.raw)

        pdfs.add(imageTokens: 2533, textTokens: 20, redactions: 1)
        let both = Pipeline.ledgerEntries(pdfs: pdfs, images: images, redacted: false)
        XCTAssertEqual(both.map(\.mode), ["pdf", "image"], "pdf first, as the CLI has always written them")
        XCTAssertEqual(both.map(\.raw), [true, true], "a run with redaction off is marked raw")
        XCTAssertTrue(Pipeline.ledgerEntries(pdfs: .init(), images: .init(), redacted: true).isEmpty)
    }

    func testLedgerEntryMarksRawOnlyWhenRedactionIsOff() {
        let e = LedgerEntry(mode: "video", inputs: 3, imageTokens: 9, textTokens: 1, redactions: 0)
        XCTAssertEqual(Pipeline.ledgerEntry(e, redacted: false).raw, true)
        XCTAssertNil(Pipeline.ledgerEntry(e, redacted: true).raw)
    }

    func testSavings() {
        XCTAssertEqual(Pipeline.savings(imageTokens: 0, textTokens: 5).saved, 0)
        XCTAssertEqual(Pipeline.savings(imageTokens: 0, textTokens: 5).pct, 0)
        XCTAssertEqual(Pipeline.savings(imageTokens: 1000, textTokens: 333).saved, 667)
        XCTAssertEqual(Pipeline.savings(imageTokens: 1000, textTokens: 333).pct, 66)
    }

    // MARK: - which rules apply

    func testRulesSourcePrecedence() throws {
        let home = tmp.path
        // Nothing named and no default file: built-in rules only.
        XCTAssertNil(Pipeline.rulesSource(explicitPath: nil, environment: ["CHEAPSHOT_HOME": home], home: home))
        // The default file next to the ledger, not named on purpose.
        let def = tmp.appendingPathComponent("rules.json")
        try "[]".write(to: def, atomically: true, encoding: .utf8)
        XCTAssertEqual(Pipeline.rulesSource(explicitPath: nil, environment: ["CHEAPSHOT_HOME": home], home: home),
                       Pipeline.RulesSource(url: def, named: false))
        // $CHEAPSHOT_RULES beats the default, and an empty one is ignored.
        XCTAssertEqual(Pipeline.rulesSource(explicitPath: nil, environment: ["CHEAPSHOT_HOME": home, "CHEAPSHOT_RULES": "/e.json"], home: home),
                       Pipeline.RulesSource(url: URL(fileURLWithPath: "/e.json"), named: true))
        XCTAssertEqual(Pipeline.rulesSource(explicitPath: nil, environment: ["CHEAPSHOT_HOME": home, "CHEAPSHOT_RULES": ""], home: home)?.named, false)
        // An explicit path beats both.
        XCTAssertEqual(Pipeline.rulesSource(explicitPath: "/x.json", environment: ["CHEAPSHOT_RULES": "/e.json"], home: home),
                       Pipeline.RulesSource(url: URL(fileURLWithPath: "/x.json"), named: true))
    }

    func testRedactorFromRules() throws {
        var warnings: [String] = []
        let custom = tmp.appendingPathComponent("custom.json")
        try #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"}]"#.write(to: custom, atomically: true, encoding: .utf8)

        let r = try Pipeline.redactor(rules: .init(url: custom, named: true)) { warnings.append($0) }
        XCTAssertEqual(r.redact("INT-123456 \(Self.fakeMail)").text, "[TICKET] [EMAIL]", "custom rules plus built-ins")
        XCTAssertEqual(try Pipeline.redactor(rules: nil) { warnings.append($0) }.rules.count, Rule.builtin.count)

        // A file named on purpose that is missing or broken is an error.
        let missing = tmp.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try Pipeline.redactor(rules: .init(url: missing, named: true)) { warnings.append($0) })
        XCTAssertTrue(warnings.isEmpty)

        // The default file broken: warn and keep the built-in rules.
        let broken = tmp.appendingPathComponent("rules.json")
        try "not json".write(to: broken, atomically: true, encoding: .utf8)
        let fallback = try Pipeline.redactor(rules: .init(url: broken, named: false)) { warnings.append($0) }
        XCTAssertEqual(fallback.rules.count, Rule.builtin.count)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("ignoring \(broken.path): "), warnings[0])
        XCTAssertTrue(warnings[0].hasSuffix("; using built-in rules only"), warnings[0])
    }
}
