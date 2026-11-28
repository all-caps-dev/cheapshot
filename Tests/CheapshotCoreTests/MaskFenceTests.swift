// Swift. CS-05 gap 4 on the mask path: `Masker.flag` paints a hit that a custom rule finds
// across an OCR'd code-fence line, so the masked copy matches the redaction it reports.
import XCTest
import CoreGraphics
@testable import CheapshotCore
@testable import CheapshotPortable

final class MaskFenceTests: XCTestCase {
    func testHitAcrossOCRFenceLineIsPainted() throws {
        let hex = "b1946ac924" + "92d2347f2a"
        let redactor = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
            ["name": "MYCREDS", "pattern": #"creds-begin\n[0-9a-f]{20}"#],
        ])))
        func row(_ text: String, _ y: CGFloat) -> (text: String, bbox: CGRect, confidence: Float) {
            (text, CGRect(x: 10, y: y, width: 200, height: 20), 1)
        }
        let lines = [row("intro", 0), row("creds-begin", 30), row("```", 60), row(hex, 90), row("outro", 120)]
        let boxes = Masker.flag(lines, redactor: redactor, minConfidence: 0.5)
        let ys = Set(boxes.filter { $0.reason == .redacted }.map(\.rect.minY))
        XCTAssertEqual(ys, [30, 60, 90], "the two lines around the fence and the fence itself are painted")
        // Two fence lines in a row between the halves are read past too.
        let two = [row("creds-begin", 0), row("```", 30), row("~~~", 60), row(hex, 90)]
        XCTAssertEqual(Masker.flag(two, redactor: redactor, minConfidence: 0.5).filter { $0.reason == .redacted }.count, 4)
        // No rule across the fence: nothing painted.
        XCTAssertTrue(Masker.flag([row("a", 0), row("```", 30), row("b", 60)], redactor: redactor, minConfidence: 0.5).isEmpty)
    }
}
