import XCTest
@testable import CheapshotCore

final class SmokeTests: XCTestCase {
    func testRedactEmail() {
        let (text, report) = redact("mail ryan@example.com now")
        XCTAssertEqual(text, "mail [EMAIL] now")
        XCTAssertEqual(report.counts["EMAIL"], 1)
    }

    func testTextTokens() {
        XCTAssertEqual(textTokens("12345678"), 2)
        XCTAssertEqual(textTokens(""), 1)
    }
}
