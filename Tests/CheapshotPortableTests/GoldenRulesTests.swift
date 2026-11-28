import XCTest
@testable import CheapshotPortable

/// Rules file v2 applied to the redactor (NOV-156, plan 7.4).
///
/// 1. Every golden case gives byte-identical output with no file, an old array file and an
///    object file that sets nothing: v2 support changes nothing for anyone who does not use it.
/// 2. Each Golden/rules/<case>/ holds rules.json, input.txt and expected.txt, plus preset.txt
///    when the case passes a --preset override. The file is read as a named file (strict).
final class GoldenRulesTests: XCTestCase {
    private func goldenRoot() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
    }

    private func contents(_ json: String, strict: Bool = true) throws -> RuleFileContents {
        try RuleFile.parseContents(Data(json.utf8), strict: strict) { XCTFail("unexpected warning: \($0)") }
    }

    func testGoldenCasesUnchangedWithNoFileArrayFileOrEmptyObject() throws {
        let root = try goldenRoot()
        let casesDir = root.appendingPathComponent("cases")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertEqual(names.count, 62)

        let files: [(String, RuleFileContents?)] = [
            ("no file", nil),
            ("empty array", try contents("[]")),
            // A custom rule that matches nothing in any case: its presence must not reorder or
            // change the built-ins.
            ("array with an unmatched rule", try contents(#"[{"name":"NEVER","pattern":"\\bZZQX-NEVER-[0-9]{9}\\b"}]"#)),
            ("empty object", try contents("{}")),
            ("object, everything", try contents(#"{"version": 2, "preset": "everything", "disabled": [], "presets": {}}"#)),
        ]
        let baseline = Redactor()
        for (label, file) in files {
            let selection = try RuleSelection.resolve(file)
            XCTAssertFalse(selection.isWeakened, label)
            let redactor = Redactor(selection: selection)
            for name in names {
                let input = GoldenTests.assemble(try String(contentsOf: casesDir.appendingPathComponent(name), encoding: .utf8))
                XCTAssertEqual(redactor.redact(input).text, baseline.redact(input).text, "\(label): golden case \(name)")
            }
        }
    }

    func testRulesCases() throws {
        let dir = try goldenRoot().appendingPathComponent("rules")
        let cases = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(cases, ["01-one-preset", "02-two-names-off", "03-group-off",
                               "04-custom-rule-off", "05-user-preset", "06-preset-override"])
        for name in cases {
            let c = dir.appendingPathComponent(name)
            let file = try RuleFile.loadContents(c.appendingPathComponent("rules.json"), strict: true) {
                XCTFail("\(name): unexpected warning \($0)")
            }
            let presetURL = c.appendingPathComponent("preset.txt")
            let override = FileManager.default.fileExists(atPath: presetURL.path)
                ? try String(contentsOf: presetURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let selection = try RuleSelection.resolve(file, presetOverride: override)
            let input = try String(contentsOf: c.appendingPathComponent("input.txt"), encoding: .utf8)
            let expected = try String(contentsOf: c.appendingPathComponent("expected.txt"), encoding: .utf8)
            XCTAssertEqual(Redactor(selection: selection).redact(input).text, expected, "rules case \(name)")

            // --all-rules ignores the toggles: the output equals a plain redactor with the
            // file's custom rules (mutation R5).
            let all = try RuleSelection.resolve(file, presetOverride: override, policy: .allRules)
            XCTAssertFalse(all.isWeakened, name)
            XCTAssertEqual(Redactor(selection: all).redact(input).text,
                           Redactor(customRules: file.customRules).redact(input).text, "all-rules \(name)")
        }
    }

    // MARK: - selection details

    /// Mutation R2: `disabled` must take effect.
    func testDisabledIsHonoured() throws {
        let s = try RuleSelection.resolve(try contents(#"{"disabled": ["EMAIL"]}"#))
        XCTAssertEqual(s.disabled, ["EMAIL"])
        XCTAssertTrue(s.isWeakened)
        XCTAssertFalse(s.rules.contains { $0.name == "EMAIL" })
        XCTAssertEqual(Redactor(selection: s).redact("ryan@example.com").text, "ryan@example.com")
    }

    /// Mutation R7: custom rules still run before the built-ins and win an overlap.
    func testCustomRulesStillFirst() throws {
        let s = try RuleSelection.resolve(try contents(#"{"disabled": ["IPV4"], "rules": [{"name": "STAFF", "pattern": "ryan@example\\.com"}]}"#))
        XCTAssertEqual(s.rules.first?.name, "STAFF")
        XCTAssertEqual(Redactor(selection: s).redact("mail ryan@example.com").text, "mail [STAFF]")
    }

    func testBuiltinOrderIsKept() throws {
        let s = try RuleSelection.resolve(try contents(#"{"preset": "secrets-only"}"#))
        let expected = Rule.builtin.filter { RuleCatalog.entry(named: $0.name)?.group == .credentials }
        XCTAssertEqual(s.rules.map(\.pattern), expected.map(\.pattern))
        XCTAssertEqual(s.disabled, RuleCatalog.names.filter { RuleCatalog.entry(named: $0)?.group != .credentials })
    }

    /// Plan 4.4 last row: an unknown --preset is an error for any file, including none.
    func testUnknownPresetOverrideThrows() throws {
        XCTAssertThrowsError(try RuleSelection.resolve(nil, presetOverride: "nope"))
        XCTAssertThrowsError(try RuleSelection.resolve(try contents("{}"), presetOverride: "nope", policy: .allRules))
        XCTAssertEqual(try RuleSelection.resolve(nil, presetOverride: "Secrets-Only").preset, "secrets-only")
    }

    /// Mutation R3 at selection time: a default file whose preset was unknown is read as no
    /// preset, which means everything, never as a preset that switches rules off.
    func testDroppedPresetMeansEverything() throws {
        var warnings: [String] = []
        let file = try RuleFile.parseContents(Data(#"{"preset": "nope"}"#.utf8), strict: false) { warnings.append($0) }
        let s = try RuleSelection.resolve(file)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(s.preset, "everything")
        XCTAssertEqual(s.disabled, [])
    }

    /// The Q5 C switch: a locked group cannot be switched off by the file or a preset.
    func testLockedGroupsStayOn() throws {
        let file = try contents(#"{"preset": "secrets-only", "disabled": ["SECRET", "JWT"]}"#)
        let s = try RuleSelection.resolve(file, policy: .locked([.credentials]))
        XCTAssertTrue(s.disabled.allSatisfy { RuleCatalog.entry(named: $0)?.group != .credentials })
        XCTAssertTrue(s.rules.contains { $0.name == "SECRET" })
        XCTAssertTrue(s.isWeakened, "the other three groups are still off")
    }

    func testNoFileIsEverything() throws {
        let s = try RuleSelection.resolve(nil)
        XCTAssertEqual(s.preset, "everything")
        XCTAssertEqual(s.rules.map(\.pattern), Rule.builtin.map(\.pattern))
        XCTAssertEqual(RuleSelection.everything.rules.map(\.pattern), Rule.builtin.map(\.pattern))
    }
}
