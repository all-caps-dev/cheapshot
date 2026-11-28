import XCTest
@testable import CheapshotPortable

/// Rules file version 2 (NOV-156): the object form and the failure-direction table in
/// ``RuleFile/parseContents(_:strict:warn:)``. The version 1 array keeps its own tests in
/// RuleFileTests, which this change leaves untouched.
final class RuleFileV2Tests: XCTestCase {
    private func parse(_ json: String, strict: Bool) throws -> (RuleFileContents, [String]) {
        var warnings: [String] = []
        let c = try RuleFile.parseContents(Data(json.utf8), strict: strict) { warnings.append($0) }
        return (c, warnings)
    }

    // Mutation R1: the old array read through the new path must give the same rules, no preset
    // and nothing disabled, for both a named and the default file.
    func testArrayFormReadsAsBefore() throws {
        let json = #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"},{"name":"HOST","pattern":"corp\\.internal","caseInsensitive":false,"enabled":false}]"#
        let old = try RuleFile.parse(Data(json.utf8))
        for strict in [true, false] {
            let (c, w) = try parse(json, strict: strict)
            XCTAssertEqual(c.version, 1)
            XCTAssertEqual(c.customRules.map(\.name), old.map(\.name), "an array ignores enabled, as it always ignored unknown keys")
            XCTAssertEqual(c.customRules.map(\.pattern), old.map(\.pattern))
            XCTAssertEqual(c.customRules.map(\.options), old.map(\.options))
            XCTAssertNil(c.preset)
            XCTAssertEqual(c.disabled, [])
            XCTAssertEqual(c.userPresets, [:])
            XCTAssertEqual(w, [])
        }
    }

    func testOldParseStillRejectsTheObjectForm() {
        XCTAssertThrowsError(try RuleFile.parse(Data(#"{"version":2}"#.utf8)))
    }

    func testFullObjectForm() throws {
        let json = #"""
        {"version": 2, "preset": "Client-Share", "disabled": ["ipv4", "group:financial"],
         "presets": {"client-share": {"disabled": ["group:network", "EMAIL"]}},
         "rules": [{"name": "EMPLOYEE_ID", "pattern": "E-[0-9]{6}", "caseInsensitive": true, "enabled": true},
                   {"name": "OFF", "pattern": "x", "enabled": false},
                   {"name": "plain", "pattern": "y"}]}
        """#
        for strict in [true, false] {
            let (c, w) = try parse(json, strict: strict)
            XCTAssertEqual(c.version, 2)
            XCTAssertEqual(c.preset, "client-share")
            XCTAssertEqual(c.disabled, ["IPV4", "IBAN", "ROUTING", "CARD", "BANK_ACCT"])
            XCTAssertEqual(c.userPresets, ["client-share": ["IPV4", "EMAIL"]])
            XCTAssertEqual(c.customRules.map(\.name), ["EMPLOYEE_ID", "PLAIN"], "enabled: false skips a rule; missing means on")
            XCTAssertEqual(w, [])
        }
    }

    func testEmptyObjectSetsNothing() throws {
        for strict in [true, false] {
            let (c, w) = try parse("{}", strict: strict)
            XCTAssertEqual(c.version, 2)
            XCTAssertNil(c.preset)
            XCTAssertEqual(c.disabled, [])
            XCTAssertTrue(c.customRules.isEmpty)
            XCTAssertEqual(w, [])
        }
    }

    func testBuiltinPresetNamesAreAccepted() throws {
        XCTAssertEqual(try parse(#"{"preset":"secrets-only"}"#, strict: true).0.preset, "secrets-only")
        XCTAssertEqual(try parse(#"{"preset":"Everything"}"#, strict: true).0.preset, "everything")
    }

    // MARK: - failure direction, plan table 4.4

    func testNotJSONThrowsForBoth() {
        for strict in [true, false] {
            XCTAssertThrowsError(try parse("{nope", strict: strict))
            XCTAssertThrowsError(try parse(#""a string""#, strict: strict))
            XCTAssertThrowsError(try parse(#"{"disabled": "IPV4"}"#, strict: strict), "wrong type is malformed")
        }
    }

    func testNewerVersionThrowsForBoth() {
        for strict in [true, false] {
            XCTAssertThrowsError(try parse(#"{"version": 3, "rules": []}"#, strict: strict)) { e in
                XCTAssertTrue("\(e)".contains("version 3"), "\(e)")
            }
        }
        XCTAssertThrowsError(try parse(#"{"version": 0}"#, strict: true))
    }

    // Mutation R3: an unknown preset must never pass silently for a named file.
    func testUnknownPresetThrowsWhenNamedWarnsOtherwise() throws {
        let json = #"{"preset": "nope", "disabled": ["IPV4"]}"#
        XCTAssertThrowsError(try parse(json, strict: true)) { e in XCTAssertTrue("\(e)".contains("nope"), "\(e)") }
        let (c, w) = try parse(json, strict: false)
        XCTAssertNil(c.preset, "default file falls back to everything")
        XCTAssertEqual(c.disabled, ["IPV4"], "the rest of the file still applies")
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("nope"))
    }

    func testUnknownDisabledNameThrowsWhenNamedWarnsOtherwise() throws {
        for json in [#"{"disabled": ["IPV4", "NOT_A_RULE"]}"#, #"{"disabled": ["IPV4", "group:nope"]}"#] {
            XCTAssertThrowsError(try parse(json, strict: true), json)
            let (c, w) = try parse(json, strict: false)
            XCTAssertEqual(c.disabled, ["IPV4"], "only the unknown name is ignored")
            XCTAssertEqual(w.count, 1)
        }
    }

    func testCustomRuleNameInDisabledIsUnknown() throws {
        // `disabled` applies to built-ins only; a custom rule is switched off with enabled: false.
        let json = #"{"disabled": ["MINE"], "rules": [{"name": "MINE", "pattern": "x"}]}"#
        XCTAssertThrowsError(try parse(json, strict: true))
        let (c, _) = try parse(json, strict: false)
        XCTAssertEqual(c.customRules.map(\.name), ["MINE"])
        XCTAssertEqual(c.disabled, [])
    }

    func testUnknownNameInUserPreset() throws {
        let json = #"{"presets": {"mine": {"disabled": ["EMAIL", "NOPE"]}}}"#
        XCTAssertThrowsError(try parse(json, strict: true))
        let (c, w) = try parse(json, strict: false)
        XCTAssertEqual(c.userPresets, ["mine": ["EMAIL"]])
        XCTAssertEqual(w.count, 1)
    }

    func testUserPresetMayNotShadowBuiltinPreset() throws {
        // Otherwise a file could redefine "everything" to switch rules off.
        let json = #"{"preset": "everything", "presets": {"Everything": {"disabled": ["group:credentials"]}}}"#
        XCTAssertThrowsError(try parse(json, strict: true))
        let (c, w) = try parse(json, strict: false)
        XCTAssertEqual(c.userPresets, [:])
        XCTAssertEqual(c.preset, "everything")
        XCTAssertEqual(w.count, 1)
    }

    // Bot review on #39/#40: an unknown key throws for a named file and warns for the default
    // file, so a misspelt "rules" never drops custom rules silently.
    func testUnknownTopLevelKeysThrowWhenStrictAndWarnOtherwise() throws {
        let json = #"{"version": 2, "colour": "blue", "disabled": ["SSN"]}"#
        XCTAssertThrowsError(try parse(json, strict: true))
        let (c, w) = try parse(json, strict: false)
        XCTAssertEqual(c.disabled, ["SSN"])
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("\"colour\""), w[0])
    }

    func testMisspeltRulesKeyIsNeverSilent() throws {
        for key in ["Rules", "rule"] {
            let json = #"{"version": 2, "\#(key)": [{"name": "ACME", "pattern": "acme-[0-9]{6}"}]}"#
            XCTAssertThrowsError(try parse(json, strict: true), key)
            let (c, w) = try parse(json, strict: false)
            XCTAssertEqual(c.customRules.count, 0)
            XCTAssertEqual(w.count, 1, key)
        }
        // A case slip names the key it meant.
        let (_, w) = try parse(#"{"Rules": []}"#, strict: false)
        XCTAssertTrue(w[0].contains("did you mean \"rules\""), w[0])
    }

    // Bot review on #39: version 1 means the array, so an object saying version 1 (or 0) is an error.
    func testObjectWithVersionBelowTwoThrows() {
        for strict in [true, false] {
            XCTAssertThrowsError(try parse(#"{"version": 1, "disabled": ["group:credentials"]}"#, strict: strict))
            XCTAssertThrowsError(try parse(#"{"version": 0}"#, strict: strict))
        }
    }

    func testBadCustomRuleThrowsForBoth() {
        for strict in [true, false] {
            XCTAssertThrowsError(try parse(#"{"rules": [{"name": "BAD", "pattern": "("}]}"#, strict: strict))
            // A switched-off rule is still validated: a broken pattern is an error either way.
            XCTAssertThrowsError(try parse(#"{"rules": [{"name": "BAD", "pattern": "(", "enabled": false}]}"#, strict: strict))
            XCTAssertThrowsError(try parse(#"{"rules": [{"name": "a b", "pattern": "x"}]}"#, strict: strict))
            XCTAssertThrowsError(try parse(#"{"rules": [{"name": "A", "pattern": "x"}, {"name": "a", "pattern": "y"}]}"#, strict: strict))
        }
    }

    func testLoadContentsMissingFileThrows() {
        XCTAssertThrowsError(try RuleFile.loadContents(URL(fileURLWithPath: "/nonexistent/rules.json"), strict: false) { _ in })
    }
}
