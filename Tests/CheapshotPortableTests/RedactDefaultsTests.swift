// Swift. The one test to edit when Ryan changes a pick for Q1 to Q4 (plan section 6).
// Every other redact test passes its policy explicitly, so it does not move when a pick does.
import XCTest
@testable import CheapshotPortable

final class RedactDefaultsTests: XCTestCase {
    func testDefaultsAreRyansPicks() {
        XCTAssertEqual(RedactDefaults.noText, .write, "Q1 option A: write a photo with no text, reason no_text")
        XCTAssertEqual(RedactDefaults.onClash, .suffix, "Q2 option A: name-redacted-2.ext")
        XCTAssertEqual(RedactDefaults.outDirNaming, .redactedSuffix, "Q3 option A: always name-redacted.ext")
        XCTAssertEqual(RedactDefaults.webP, .writePNG, "Q4 option A: write a PNG and say converted")

        // The redact policy reads Q1; the mask policy is #29's behaviour and no pick moves it.
        XCTAssertEqual(RedactPolicy.redact, RedactPolicy(noText: RedactDefaults.noText, blankScreenshot: .write))
        XCTAssertEqual(RedactPolicy.mask, RedactPolicy(noText: .write, blankScreenshot: .refuse))
    }
}
