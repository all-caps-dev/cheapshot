import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import CheapshotCore

final class PDFSourceTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    enum Page { case text([String], font: String); case blank }

    /// A real PDF with a real text layer, drawn with CoreText so PDFKit can read it back.
    func makePDF(_ pages: [Page], name: String = "t.pdf") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            ctx.beginPDFPage(nil)
            switch page {
            case .text(let lines, let fontName):
                let font = CTFontCreateWithName(fontName as CFString, 12, nil)
                var y: CGFloat = 720
                for l in lines {
                    let attr = NSAttributedString(string: l, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                    ctx.textPosition = CGPoint(x: 72, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                    y -= 16
                }
            case .blank:
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(CGRect(x: 72, y: 72, width: 200, height: 100))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A page whose visible words are pixels (an image, so no text layer of their own) with an
    /// invisible text layer on top, the way an OCR'd scan is built. `layer` is what PDFKit reads
    /// back; `visible` is what a person, and Vision, sees. Making them disagree is the bug.
    func makeScanWithLayerPDF(visible: [String], layer: [String], name: String = "scan.pdf") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        // The visible words, drawn into a 2x bitmap and placed as an image.
        let bmp = try XCTUnwrap(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bmp.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); bmp.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        var y: CGFloat = 1440
        for l in visible {
            let attr = NSAttributedString(string: l, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            bmp.textPosition = CGPoint(x: 144, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), bmp)
            y -= 48
        }
        ctx.draw(try XCTUnwrap(bmp.makeImage()), in: box)
        // The text layer, invisible, at the same positions in points.
        ctx.setTextDrawingMode(.invisible)
        let small = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        y = 720
        for l in layer {
            let attr = NSAttributedString(string: l, attributes: [kCTFontAttributeName as NSAttributedString.Key: small])
            ctx.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            y -= 24
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    static let prose = ["Quarterly revenue grew twelve percent this year",
                        "Operating costs fell by three percent overall",
                        "The board approved the budget for next spring"]

    /// Reported 2026-09-29 on real papers: the layer was `! " % &` and the old 20-character test
    /// took it as text, so the garbage came out instead of the words on the page.
    func testGarbledTextLayerFallsBackToOCR() throws {
        let garbage = ["! \" % & ' ! \" % & ' ! \" %", "\" % ! & ' \" % ! & ' \" %", "% & ! \" ' % & ! \" ' %"]
        let url = try makeScanWithLayerPDF(visible: Self.prose, layer: garbage)
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertGreaterThanOrEqual((page.string ?? "").filter { !$0.isWhitespace }.count, PDFSource.scanLaneThreshold,
                                    "the fixture must pass the old character-count test, or it does not reproduce the bug")
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .scan)
        let text = Layout.text(p.lines)
        XCTAssertTrue(text.contains("revenue grew twelve"), text)
        XCTAssertFalse(text.contains("! \" %"), text)
    }

    /// The other report: a layer that reads as words but silently leaves out a line.
    func testTextLayerThatDropsALineFallsBackToOCR() throws {
        let url = try makeScanWithLayerPDF(visible: Self.prose, layer: [Self.prose[0], Self.prose[2]])
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .scan)
        XCTAssertTrue(Layout.text(p.lines).contains("costs fell by three"), Layout.text(p.lines))
    }

    /// A layer that says what the page shows stays on the text lane, exact and unfenced.
    func testFaithfulTextLayerStaysOnTheTextLane() throws {
        let url = try makeScanWithLayerPDF(visible: Self.prose, layer: Self.prose)
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .text)
        XCTAssertEqual(p.lines.map(\.text), Self.prose)
    }

    func testForceOCRSkipsAGoodTextLayer() throws {
        let url = try makePDF([.text(Self.prose, font: "Helvetica")])
        XCTAssertEqual(try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0].lane, .text)
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3, forceOCR: true).pages[0]
        XCTAssertEqual(p.lane, .scan)
        XCTAssertTrue(Layout.text(p.lines).contains("Operating costs fell"), Layout.text(p.lines))
    }

    /// The comparison itself, without Vision: which OCR lines the layer does not account for.
    func testLayerMissesCountsOnlyLinesTheLayerLacks() {
        let layer = Self.prose.joined(separator: "\n")
        XCTAssertEqual(PDFSource.layerMisses(layer: layer, ocrLines: Self.prose), 0)
        // OCR noise on one word of a line is not a missing line.
        XCTAssertEqual(PDFSource.layerMisses(layer: layer, ocrLines: ["Quarterly revenue grew twelve percenl this year"]), 0)
        XCTAssertEqual(PDFSource.layerMisses(layer: layer, ocrLines: ["Staff numbers stayed flat across every region"]), 1)
        XCTAssertEqual(PDFSource.layerMisses(layer: "! \" % & ' ! \" % &", ocrLines: Self.prose), 3)
        // Too few words to judge: headings, code, page numbers never count against the layer.
        XCTAssertEqual(PDFSource.layerMisses(layer: layer, ocrLines: ["Table 3", "def main():", "264"]), 0)
        // A ligature in the layer and the plain letters in OCR are the same word.
        XCTAssertEqual(PDFSource.layerMisses(layer: "the ﬁnal ﬁgures were ﬁled on time", ocrLines: ["the final figures were filed on time"]), 0)
    }

    func testTextLaneReadsLinesWithBoxesAndMonospaceFence() throws {
        let url = try makePDF([.text(["def main():", "return 1", "print(main())"], font: "Menlo")])
        let doc = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3)
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(doc.pages.count, 1)
        let p = doc.pages[0]
        XCTAssertEqual(p.n, 1)
        XCTAssertEqual(p.lane, .text)
        XCTAssertEqual(p.lines.map(\.text), ["def main():", "return 1", "print(main())"])
        XCTAssertEqual(p.lines.map(\.n), [1, 2, 3])
        XCTAssertTrue(p.lines.allSatisfy { $0.confidence == 1.0 })
        XCTAssertTrue(p.lines.allSatisfy(\.fenced), "Menlo is fixed pitch, so the lines are fenced")
        XCTAssertEqual(p.lines[0].bbox.minX, 72, accuracy: 3)
        XCTAssertLessThan(p.lines[0].bbox.minY, p.lines[1].bbox.minY, "top-left origin: first line has the smaller y")
        XCTAssertEqual(p.width, 1224); XCTAssertEqual(p.height, 1584)
        XCTAssertEqual(PDFSource.text(of: doc), "--- page 1 ---\n```\ndef main():\nreturn 1\nprint(main())\n```")
    }

    func testProportionalFontIsNotFenced() throws {
        let url = try makePDF([.text(["Quarterly report", "Revenue grew twelve percent."], font: "Helvetica")])
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .text)
        XCTAssertFalse(p.lines.contains(where: \.fenced))
    }

    func testScanLaneForPageWithoutText() throws {
        let url = try makePDF([.blank])
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .scan)       // OCR content is not asserted; a grey box has no text
        XCTAssertEqual(p.width, 1224)
    }

    func testPageRangeAndValidation() throws {
        let url = try makePDF([.text(["one"], font: "Helvetica"), .text(["two two two two two"], font: "Helvetica"), .text(["three three three three"], font: "Helvetica")])
        let doc = try PDFSource.pages(of: url, range: 2...2, minConfidence: 0.3)
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.pages.map(\.n), [2])
        XCTAssertThrowsError(try PDFSource.pages(of: url, range: 3...4, minConfidence: 0.3))
        XCTAssertThrowsError(try PDFSource.pages(of: tmp.appendingPathComponent("missing.pdf"), range: nil, minConfidence: 0.3))
    }

    /// A locked document opens: `PDFDocument(url:)` returns non-nil with a real `pageCount`, but
    /// every `page.string` is nil and every render is blank. Without the guard the whole file went
    /// to the scan lane, OCR'd to nothing, and exited 0 with a fabricated saving.
    func testPasswordProtectedPDFThrows() throws {
        let plain = try makePDF([.text(["a page with plenty of readable text on it"], font: "Helvetica")], name: "plain.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: plain))
        let locked = tmp.appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "x"]))
        let reopened = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(reopened.isLocked, "the fixture has to actually be locked")
        XCTAssertGreaterThan(reopened.pageCount, 0, "and to report pages, which is what fooled the scan lane")
        XCTAssertThrowsError(try PDFSource.pages(of: locked, range: nil, minConfidence: 0.3)) { error in
            XCTAssertTrue("\(error)".contains("password-protected"), "\(error)")
            XCTAssertTrue("\(error)".contains("locked.pdf"), "\(error)")
        }
    }

    func testSHA256() throws {
        let f = tmp.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try PDFSource.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = try makePDF([.blank], name: "s.pdf")
        XCTAssertEqual(try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).sha256, try PDFSource.sha256(of: url))
    }

    /// A one-page PDF whose media box does not start at the origin, with one filled bar whose
    /// position in the render is known exactly: 10pt in from the box's left edge and 50pt down
    /// from its top, so at 2x the ink must land at x 20-220, y 100-200 from the top-left.
    func makeOffsetBoxPDF(name: String = "offset.pdf") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 50, y: 100, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 792, width: 100, height: 50))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// A one-page PDF, no text layer, with a filled bar high on the page: far enough up that a
    /// quarter-turn maps it past 612pt horizontally, so it clips away entirely if the bitmap is
    /// sized from the unrotated box. That is what makes the blank-render assertion below bite.
    func makeHighBarPDF(name: String = "bar.pdf") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 72, y: 700, width: 200, height: 60))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// The same document with `/Rotate` set on its first page, written back out by PDFKit.
    func rotated(_ url: URL, by degrees: Int, name: String) throws -> URL {
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        page.rotation = degrees
        let out = tmp.appendingPathComponent(name)
        XCTAssertTrue(doc.write(to: out))
        return out
    }

    /// How much of the bitmap is not white, and where that ink sits in top-left pixel coordinates.
    /// A rendered page that comes back blank is the bug this measures; OCR would not catch it.
    func ink(_ image: CGImage) throws -> (fraction: Double, box: CGRect) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0, minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard bytes[i] < 240 || bytes[i + 1] < 240 || bytes[i + 2] < 240 else { continue }
                n += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard n > 0 else { return (0, .null) }
        return (Double(n) / Double(w * h),
                CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)))
    }

    func testRotatedPageRendersItsInkAndSwapsTheBitmap() throws {
        let url = try rotated(try makeHighBarPDF(name: "upright.pdf"), by: 90, name: "turned.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(page.rotation, 90)
        // bounds(for:) ignores /Rotate, so the size has to come from pixelSize, not from the box.
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612)
        let size = PDFSource.pixelSize(page)
        XCTAssertEqual(size.width, 1584); XCTAssertEqual(size.height, 1224)
        let measured = try ink(try PDFSource.render(page, width: size.width, height: size.height))
        XCTAssertGreaterThan(measured.fraction, 0.005, "a quarter-turned page must not render blank")
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .scan)
        XCTAssertEqual(p.width, 1584); XCTAssertEqual(p.height, 1224)
    }

    func testOffsetMediaBoxIsNotShiftedTwice() throws {
        let url = try makeOffsetBoxPDF()
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).minX, 50)
        let size = PDFSource.pixelSize(page)
        XCTAssertEqual(size.width, 1224); XCTAssertEqual(size.height, 1584)
        let measured = try ink(try PDFSource.render(page, width: size.width, height: size.height))
        XCTAssertGreaterThan(measured.fraction, 0.005)
        XCTAssertEqual(measured.box.minX, 20, accuracy: 3, "the bar sits 10pt in from the box's left edge")
        XCTAssertEqual(measured.box.maxX, 220, accuracy: 3)
        XCTAssertEqual(measured.box.minY, 100, accuracy: 3, "and 50pt down from the box's top edge")
        XCTAssertEqual(measured.box.maxY, 200, accuracy: 3)
    }

    /// The page-level attributed string is what the fence verdict indexes into, so its index space
    /// has to agree with `page.string`. When it stops agreeing, `textLines` fences nothing.
    func testPageAttributedStringSharesTheIndexSpaceOfPageString() throws {
        let url = try makePDF([.text(["def main():", "return 1", "print(main())"], font: "Menlo")])
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let string = try XCTUnwrap(page.string)
        XCTAssertEqual(page.attributedString?.length, (string as NSString).length)
        XCTAssertEqual(page.attributedString?.string, string)
    }
}
