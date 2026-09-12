import XCTest
@testable import CheapshotCore

final class ValidatorsTests: XCTestCase {
    func testLuhn() {
        XCTAssertTrue(Validators.luhn("4111 1111 1111 1111"))
        XCTAssertFalse(Validators.luhn("4111-1111-1111-1112"))
        XCTAssertFalse(Validators.luhn("123456789012"))   // 12 digits, too short
    }

    func testABA() {
        XCTAssertTrue(Validators.aba("021000021"))
        XCTAssertFalse(Validators.aba("123456789"))
        XCTAssertFalse(Validators.aba("02100002"))
    }

    func testEntropy() {
        XCTAssertEqual(Validators.entropy(""), 0)
        XCTAssertEqual(Validators.entropy("aaaa"), 0)
        XCTAssertEqual(Validators.entropy("ab"), 1, accuracy: 0.0001)
    }

    func testLooksLikeSecret() {
        XCTAssertFalse(Validators.looksLikeSecret("https://example.com/AbCdEf"))
        XCTAssertFalse(Validators.looksLikeSecret("/Users/ryan/local-dev/Cheapshot"))
        XCTAssertTrue(Validators.looksLikeSecret("dGhpcyBpcyBhIHNlY3JldCB0b2tlbiBub2JvZHkgc2hvdWxkIHNlZQ=="))
    }
}
