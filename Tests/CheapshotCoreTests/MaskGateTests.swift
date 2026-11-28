// Swift. The CHE-24 mask gate (`Masker.refusesBlank`) as a pure decision, so no Vision call runs.
// `Masker.mask` takes no injected OCR, so these cases are what pins the boxes-not-lines rule.
import XCTest
import CoreGraphics
@testable import CheapshotCore

final class MaskGateTests: XCTestCase {
    let oneBox = [MaskBox(rect: CGRect(x: 10, y: 10, width: 80, height: 20), reason: .lowConfidence)]

    /// Screenshot-like, checked read not ok after the retry, nothing painted: refuse.
    func testRefusesScreenshotLikeEmptyReadWithNoBoxes() {
        XCTAssertTrue(Masker.refusesBlank(screenshotLike: true, status: .empty, boxes: []))
    }

    /// Faint or low-confidence text: the checked lines are empty (filtered at the floor), but the
    /// confidence-0 passes painted boxes, so mask it rather than refuse.
    func testMasksWhenBoxesExistEvenIfTheCheckedReadIsEmpty() {
        XCTAssertFalse(Masker.refusesBlank(screenshotLike: true, status: .empty, boxes: oneBox))
    }

    /// A photo is not retried and not gated: an empty read there is an answer.
    func testNonScreenshotLikeImageIsNeverRefused() {
        XCTAssertFalse(Masker.refusesBlank(screenshotLike: false, status: .empty, boxes: []))
        XCTAssertFalse(Masker.refusesBlank(screenshotLike: false, status: .ok, boxes: []))
    }

    /// A confirmed read is never refused, boxes or not (a clean screenshot has nothing to paint).
    func testOkReadIsNeverRefused() {
        XCTAssertFalse(Masker.refusesBlank(screenshotLike: true, status: .ok, boxes: []))
        XCTAssertFalse(Masker.refusesBlank(screenshotLike: true, status: .ok, boxes: oneBox))
    }

    /// Clean lines seen but zero boxes still refuses. Scenario: the checked read cold-failed (Vision
    /// not warm yet, so `.empty` even after the retry), then the warmer `findBoxes` passes saw only
    /// clean lines above the floor, so nothing was painted. The copy would be the original. A gate
    /// keyed on a line count from those passes would let it through; keying on boxes refuses it.
    func testCleanLinesButZeroBoxesAfterAColdCheckedReadStillRefuses() {
        XCTAssertTrue(Masker.refusesBlank(screenshotLike: true, status: .empty, boxes: []),
                      "the gate keys on boxes, not lines")
    }

    /// The refusal never hands the model the allow command, and does not claim there was no text.
    func testRefusalWording() {
        XCTAssertFalse(Masker.blankRefusal.contains("cheapshot allow"))
        XCTAssertFalse(Masker.blankRefusal.contains("no text"))
        XCTAssertTrue(Masker.blankRefusal.contains("looks like a screenshot"))
        XCTAssertTrue(Masker.blankRefusal.contains("a person can approve the original from a terminal"))
    }
}
