import XCTest
@testable import CheapshotCore

final class TokensTests: XCTestCase {
    func testImageTokensUseTheDownscaleRule() {
        XCTAssertEqual(Tokens.image(width: 750, height: 1), 1)
        XCTAssertEqual(Tokens.image(width: 1000, height: 1000), 1333)
        XCTAssertEqual(Tokens.image(width: 3136, height: 1568), 1639, "long edge scaled to 1568 first")
        XCTAssertEqual(Tokens.image(width: 0, height: 0), 0)
    }

    func testTextTokens() {
        XCTAssertEqual(Tokens.text(""), 1)
        XCTAssertEqual(Tokens.text("12345678"), 2)
        XCTAssertEqual(Tokens.text("123456789"), 2)
        XCTAssertEqual(Tokens.text("1234567890"), 3)
    }
}
