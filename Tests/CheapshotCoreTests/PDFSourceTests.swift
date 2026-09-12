import XCTest
import CoreGraphics
import CoreText
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

    func testSHA256() throws {
        let f = tmp.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try PDFSource.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = try makePDF([.blank], name: "s.pdf")
        XCTAssertEqual(try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).sha256, try PDFSource.sha256(of: url))
    }
}
