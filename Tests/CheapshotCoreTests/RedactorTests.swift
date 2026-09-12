import XCTest
@testable import CheapshotCore

final class RedactorTests: XCTestCase {
    func testBuiltinRedactsEmail() {
        let (text, report) = Redactor().redact("mail ryan@example.com now")
        XCTAssertEqual(text, "mail [EMAIL] now")
        XCTAssertEqual(report.counts["EMAIL"], 1)
        XCTAssertEqual(report.total, 1)
    }

    func testCardRuleUsesLuhnValidator() {
        XCTAssertEqual(Redactor().redact("card 4111 1111 1111 1111").text, "card [CARD]")
        XCTAssertEqual(Redactor().redact("card 4111-1111-1111-1112").text, "card 4111-1111-1111-1112")
    }

    func testCustomRulesRunFirst() {
        let custom = Rule(name: "TICKET", pattern: #"\bINT-\d{6}\b"#)
        let r = Redactor(customRules: [custom])
        XCTAssertEqual(r.rules.first?.name, "TICKET")
        XCTAssertEqual(r.rules.count, Rule.builtin.count + 1)
        XCTAssertEqual(r.redact("see INT-123456 and ryan@example.com").text, "see [TICKET] and [EMAIL]")
    }

    func testEmptyRulesIsIdentity() {
        XCTAssertEqual(Redactor(rules: []).redact("ryan@example.com").text, "ryan@example.com")
    }

    func testVersionConstant() {
        XCTAssertEqual(cheapshotVersion, "0.4.1")
    }
}
