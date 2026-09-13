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

    // Card 1862718065720952052: the name becomes the [NAME] placeholder, so it must be a clean token
    // and unique within the file.
    func testRejectsNameThatCannotBePlaceholder() {
        for bad in ["a]b", "my rule", "", "x[y", "über"] {
            let json = #"[{"name":"\#(bad)","pattern":"x"}]"#
            XCTAssertThrowsError(try RuleFile.parse(Data(json.utf8)), "name \(bad) should be rejected") { error in
                XCTAssertTrue("\(error)".contains("name"), "error should say it is the name: \(error)")
            }
        }
        XCTAssertEqual(try RuleFile.parse(Data(#"[{"name":"my_rule-2","pattern":"x"}]"#.utf8)).map(\.name), ["MY_RULE-2"])
    }

    func testRejectsDuplicateNames() {
        let json = #"[{"name":"host","pattern":"a"},{"name":"HOST","pattern":"b"}]"#
        XCTAssertThrowsError(try RuleFile.parse(Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("HOST") && "\(error)".contains("duplicate"), "\(error)")
        }
    }

    func testRejectsNotAnArray() {
        XCTAssertThrowsError(try RuleFile.parse(Data(#"{"name":"X"}"#.utf8)))
    }

    func testLoadMissingFileThrows() {
        XCTAssertThrowsError(try RuleFile.load(URL(fileURLWithPath: "/nonexistent/rules.json")))
    }
}
