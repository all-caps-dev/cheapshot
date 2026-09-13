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

    // Card 1862723135569134862: fractional scale suffixes are not email domains either.
    func testEmailSkipsFractionalScaleSuffix() {
        let name = "CleanShot 2026-09-12 at 10.22.33@2.5x.png"
        XCTAssertEqual(Redactor().redact(name).text, name)
        XCTAssertEqual(Redactor().redact("icon@1.5x.png and ryan@example.com").text, "icon@1.5x.png and [EMAIL]")
    }

    // Card 1862718065041474800: a rule that does not compile is reported, never dropped in silence.
    func testCompileFailuresAreReported() throws {
        let bad = Rule(name: "BAD", pattern: "(")
        let good = Rule(name: "GOOD", pattern: "x")
        let r = Redactor(rules: [good, bad])
        XCTAssertEqual(r.compileFailures.map(\.name), ["BAD"])
        XCTAssertEqual(r.redact("x").text, "[GOOD]")
        XCTAssertThrowsError(try Redactor(validating: [good, bad])) { error in
            XCTAssertTrue("\(error)".contains("BAD"), "error should name the rule: \(error)")
        }
        XCTAssertNoThrow(try Redactor(validating: [good]))
        XCTAssertTrue(Redactor().compileFailures.isEmpty)
    }

    func testVersionConstant() {
        XCTAssertEqual(cheapshotVersion, "0.5.0-dev")
    }
}
