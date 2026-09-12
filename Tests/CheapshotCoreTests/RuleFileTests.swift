import XCTest
@testable import CheapshotCore

final class RuleFileTests: XCTestCase {
    func testParsesRulesAndDefaults() throws {
        let json = #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"},{"name":"HOST","pattern":"corp\\.internal","caseInsensitive":false}]"#
        let rules = try RuleFile.parse(Data(json.utf8))
        XCTAssertEqual(rules.map(\.name), ["TICKET", "HOST"])
        XCTAssertEqual(rules[0].options, [.caseInsensitive])
        XCTAssertEqual(rules[1].options, [])
        XCTAssertEqual(Redactor(customRules: rules).redact("INT-123456 at corp.internal").text, "[TICKET] at [HOST]")
    }

    func testRejectsBadRegex() {
        let json = #"[{"name":"BAD","pattern":"("}]"#
        XCTAssertThrowsError(try RuleFile.parse(Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("BAD"), "error should name the rule: \(error)")
        }
    }

    func testRejectsNotAnArray() {
        XCTAssertThrowsError(try RuleFile.parse(Data(#"{"name":"X"}"#.utf8)))
    }

    func testLoadMissingFileThrows() {
        XCTAssertThrowsError(try RuleFile.load(URL(fileURLWithPath: "/nonexistent/rules.json")))
    }
}
