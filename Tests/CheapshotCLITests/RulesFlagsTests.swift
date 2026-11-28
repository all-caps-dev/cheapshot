import XCTest
import CoreGraphics
import CoreText
@testable import CheapshotCLI
import CheapshotCore

/// Rules file v2 on the command line (NOV-156, CHE-61): --preset, --all-rules, --list-rules and
/// the marks a weakened run leaves (one stderr line, a "rules" key in --json, rules_off in the
/// ledger). A run with every built-in on must show none of the three.
final class RulesFlagsTests: XCTestCase {
    var tmp: URL!
    let sample = "mail ryan@example.com password=hunter2x9q"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], stdin: String = "") async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { stdin },
                       environment: ["CHEAPSHOT_HOME": tmp.path], home: tmp.path)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    func file(_ name: String, _ body: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The default rules.json, next to the ledger.
    func defaultFile(_ body: String) throws { _ = try file("rules.json", body) }

    func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func ledgerLines() throws -> [String] {
        guard let body = try? String(contentsOf: tmp.appendingPathComponent("ledger.jsonl"), encoding: .utf8) else { return [] }
        return body.split(separator: "\n").map(String.init)
    }

    /// A one-page PDF with a text layer, so a files run takes the text lane (no OCR) and writes
    /// a ledger line.
    func textPDF() throws -> String {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attr = NSAttributedString(string: "a page with plenty of readable text on it, mail ryan@example.com",
                                      attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url.path
    }

    static let secretsOnlyOff = RuleCatalog.names.filter { RuleCatalog.entry(named: $0)?.group != .credentials }

    // MARK: - default runs stay unmarked

    func testDefaultRunHasNoMarks() async throws {
        let r = await run(["--json", "--text", "-"], stdin: sample)
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.err, "")
        let j = try json(r.out)
        XCTAssertNil(j["rules"])
        let text = try XCTUnwrap((j["results"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "mail [EMAIL] password=[SECRET]")
    }

    func testDefaultFilesRunLedgerHasNoRulesOff() async throws {
        let r = await run([try textPDF()])
        XCTAssertEqual(r.code, 0, r.err)
        let lines = try ledgerLines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains { $0.contains("rules_off") }, "\(lines)")
    }

    func testOldArrayAndEmptyObjectFilesAreUnmarked() async throws {
        for body in [#"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"}]"#, "{}", #"{"version":2,"preset":"everything"}"#] {
            let rules = try file("r.json", body)
            let r = await run(["--rules", rules, "--json", "--text", "-"], stdin: sample)
            XCTAssertEqual(r.code, 0, body)
            XCTAssertEqual(r.err, "", body)
            XCTAssertNil(try json(r.out)["rules"], body)
        }
    }

    // MARK: - weakened runs are marked three ways

    func testPresetInFileMarksStderrJSONAndLedger() async throws {
        let rules = try file("r.json", #"{"version": 2, "preset": "secrets-only"}"#)
        let n = Self.secretsOnlyOff.count

        let t = await run(["--rules", rules, "--json", "--text", "-"], stdin: sample)
        XCTAssertEqual(t.code, 0)
        XCTAssertEqual(t.err, "cheapshot: \(n) built-in rules are off (preset secrets-only)\n")
        let j = try json(t.out)
        let mark = try XCTUnwrap(j["rules"] as? [String: Any])
        XCTAssertEqual(mark["preset"] as? String, "secrets-only")
        XCTAssertEqual(mark["disabled"] as? [String], Self.secretsOnlyOff)
        let text = try XCTUnwrap((j["results"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "mail ryan@example.com password=[SECRET]")

        let f = await run(["--rules", rules, try textPDF()])
        XCTAssertEqual(f.code, 0, f.err)
        let line = try XCTUnwrap(try ledgerLines().last)
        XCTAssertEqual(try json(line)["rules_off"] as? Int, n)
    }

    func testPresetFlagWithNoFile() async throws {
        let r = await run(["--preset", "secrets-only", "--json", "--text", "-"], stdin: sample)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.err.contains("built-in rules are off (preset secrets-only)"), r.err)
        XCTAssertNotNil(try json(r.out)["rules"])
    }

    func testOneRuleOffIsSingular() async throws {
        let rules = try file("r.json", #"{"disabled": ["IPV4"]}"#)
        let r = await run(["--rules", rules, "--text", "-"], stdin: "x")
        XCTAssertEqual(r.err, "cheapshot: 1 built-in rule is off (preset everything)\n")
    }

    func testPresetFlagOverridesFilePreset() async throws {
        let rules = try file("r.json", #"{"preset": "secrets-only"}"#)
        let r = await run(["--rules", rules, "--preset", "everything", "--json", "--text", "-"], stdin: sample)
        XCTAssertEqual(r.err, "")
        XCTAssertNil(try json(r.out)["rules"])
    }

    // MARK: - --all-rules

    /// Mutation R5: --all-rules must ignore every toggle, in a named and in the default file.
    func testAllRulesIgnoresToggles() async throws {
        let rules = try file("r.json", #"{"preset": "secrets-only", "disabled": ["SECRET"]}"#)
        try defaultFile(#"{"preset": "secrets-only"}"#)
        for args in [["--rules", rules], [], ["--preset", "secrets-only"]] {
            let r = await run(args + ["--all-rules", "--json", "--text", "-"], stdin: sample)
            XCTAssertEqual(r.code, 0, "\(args)")
            XCTAssertEqual(r.err, "", "\(args)")
            let j = try json(r.out)
            XCTAssertNil(j["rules"], "\(args)")
            let text = try XCTUnwrap((j["results"] as? [[String: Any]])?.first?["text"] as? String)
            XCTAssertEqual(text, "mail [EMAIL] password=[SECRET]", "\(args)")
        }
    }

    func testAllRulesKeepsCustomRules() async throws {
        let rules = try file("r.json", #"{"preset": "secrets-only", "rules": [{"name": "TICKET", "pattern": "INT-[0-9]{6}"}]}"#)
        let r = await run(["--rules", rules, "--all-rules", "--text", "-"], stdin: "INT-123456 ryan@example.com")
        XCTAssertEqual(r.out, "[TICKET] [EMAIL]\n")
    }

    // MARK: - failure direction

    func testUnknownPresetFlagExits2() async throws {
        let r = await run(["--preset", "nope", "--text", "-"], stdin: "x")
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("nope"), r.err)
        // Even with only a default file present.
        try defaultFile("{}")
        let d = await run(["--preset", "nope", "--text", "-"], stdin: "x")
        XCTAssertEqual(d.code, 2)
    }

    func testNamedFileProblemsExit2() async throws {
        for body in [#"{"preset": "nope"}"#, #"{"disabled": ["NOPE"]}"#, #"{"version": 3}"#,
                     #"{"presets": {"everything": {}}}"#, #"{"disabled": 1}"#] {
            let rules = try file("r.json", body)
            let r = await run(["--rules", rules, "--text", "-"], stdin: "x")
            XCTAssertEqual(r.code, 2, body)
            // The Read hook recognises a broken rules file by this prefix (cheapshot-read.sh, failed()).
            XCTAssertTrue(r.err.hasPrefix("cheapshot: rules file"), "\(body): \(r.err)")
        }
    }

    /// Mutation R4: a broken default file never switches rules off.
    func testDefaultFileProblemsWarnAndKeepEveryRule() async throws {
        for body in [#"{"preset": "nope"}"#, #"{"version": 3, "preset": "secrets-only"}"#, "not json",
                     #"{"preset": "secrets-only", "disabled": "IPV4"}"#] {
            try defaultFile(body)
            let r = await run(["--json", "--text", "-"], stdin: sample)
            XCTAssertEqual(r.code, 0, body)
            XCTAssertTrue(r.err.contains("warning"), "\(body): \(r.err)")
            XCTAssertFalse(r.err.contains("are off"), body)
            let text = try XCTUnwrap((try json(r.out)["results"] as? [[String: Any]])?.first?["text"] as? String)
            XCTAssertEqual(text, "mail [EMAIL] password=[SECRET]", body)
        }
    }

    func testDefaultFileUnknownNameIgnoresOnlyThatName() async throws {
        try defaultFile(#"{"disabled": ["EMAIL", "NOPE"]}"#)
        let r = await run(["--text", "-"], stdin: sample)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.err.contains("NOPE"), r.err)
        XCTAssertTrue(r.err.contains("1 built-in rule is off"), r.err)
        XCTAssertEqual(r.out, "mail ryan@example.com password=[SECRET]\n")
    }

    // MARK: - --list-rules

    func testListRulesText() async throws {
        let rules = try file("r.json", #"{"preset": "secrets-only", "rules": [{"name": "TICKET", "pattern": "x"}]}"#)
        let r = await run(["--list-rules", "--rules", rules])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.err, "", "listing is not a run: no weakened-run line")
        let lines = r.out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("preset: secrets-only"), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("on ") && $0.contains("AWS_KEY") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("off") && $0.contains("EMAIL") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("on ") || $0.hasPrefix("off") }.count, RuleCatalog.names.count)
        XCTAssertTrue(lines.last?.contains("TICKET") == true)
    }

    func testListRulesJSON() async throws {
        let r = await run(["--list-rules", "--json", "--preset", "secrets-only"])
        XCTAssertEqual(r.code, 0, r.err)
        let j = try json(r.out)
        XCTAssertEqual(j["preset"] as? String, "secrets-only")
        XCTAssertEqual(j["presets"] as? [String], ["everything", "secrets-only"])
        XCTAssertEqual(j["disabled"] as? [String], Self.secretsOnlyOff)
        let rows = try XCTUnwrap(j["rules"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["name"] as? String }, RuleCatalog.names)
        let email = try XCTUnwrap(rows.first { $0["name"] as? String == "EMAIL" })
        XCTAssertEqual(email["on"] as? Bool, false)
        XCTAssertEqual(email["group"] as? String, "personal")
        XCTAssertEqual(rows.first { $0["name"] as? String == "SECRET" }?["on"] as? Bool, true)
    }

    /// Ryan's pick on the #40 second review: with ROUTING off, BANK_ACCT shows as partial
    /// (no MICR cue) in --list-rules and in the weakened-run marks; with both off, or both on,
    /// nothing is partial.
    func testRoutingOffShowsBankAcctPartial() async throws {
        let rules = try file("r.json", #"{"disabled": ["ROUTING"]}"#)

        let t = await run(["--list-rules", "--rules", rules])
        XCTAssertEqual(t.code, 0, t.err)
        let lines = t.out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix("(36 of 37 built-in rules on, 1 partial)"), lines[0])
        let bank = try XCTUnwrap(lines.first { $0.contains("BANK_ACCT") })
        XCTAssertTrue(bank.hasPrefix("on ") && bank.hasSuffix("partial (no MICR cue)"), bank)
        XCTAssertFalse(lines.contains { $0.contains("CARD") && $0.contains("partial") })

        let j = try json(await run(["--list-rules", "--json", "--rules", rules]).out)
        XCTAssertEqual(j["partial"] as? [String: String], ["BANK_ACCT": "no MICR cue"])
        let rows = try XCTUnwrap(j["rules"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["name"] as? String == "BANK_ACCT" }?["partial"] as? String, "no MICR cue")
        XCTAssertEqual(rows.filter { $0["partial"] != nil }.count, 1)

        let r = await run(["--rules", rules, "--json", "--text", "-"], stdin: "x")
        XCTAssertEqual(r.err, "cheapshot: 1 built-in rule is off (preset everything); BANK_ACCT is partial (no MICR cue)\n")
        let mark = try XCTUnwrap(try json(r.out)["rules"] as? [String: Any])
        XCTAssertEqual(mark["partial"] as? [String: String], ["BANK_ACCT": "no MICR cue"])

        // Both off (group:financial): BANK_ACCT is off, not partial.
        let fin = try file("f.json", #"{"disabled": ["group:financial"]}"#)
        let g = await run(["--rules", fin, "--json", "--text", "-"], stdin: "x")
        XCTAssertFalse(g.err.contains("partial"), g.err)
        XCTAssertNil((try json(g.out)["rules"] as? [String: Any])?["partial"])
        let none = try json(await run(["--list-rules", "--json"]).out)
        XCTAssertEqual(none["partial"] as? [String: String], [:])
    }

    func testListRulesDefaultIsAllOnAndAllRulesWins() async throws {
        let a = await run(["--list-rules", "--json"])
        let all = try json(a.out)
        XCTAssertEqual(all["preset"] as? String, "everything")
        XCTAssertEqual(all["disabled"] as? [String], [])
        try defaultFile(#"{"preset": "secrets-only"}"#)
        let f = await run(["--list-rules", "--json", "--all-rules"])
        let forced = try json(f.out)
        XCTAssertEqual(forced["disabled"] as? [String], [])
    }

    func testListRulesBadFileExits2() async throws {
        let rules = try file("r.json", #"{"preset": "nope"}"#)
        let r = await run(["--list-rules", "--rules", rules])
        XCTAssertEqual(r.code, 2)
    }

    // MARK: - parsing

    func testOptionsParse() throws {
        let o = try Options.parse(["--preset", "secrets-only", "--all-rules", "a.png"])
        XCTAssertEqual(o.preset, "secrets-only")
        XCTAssertTrue(o.allRules)
        XCTAssertEqual(try Options.parse(["--list-rules"]).command, .listRules(json: false))
        XCTAssertEqual(try Options.parse(["--list-rules", "--json"]).command, .listRules(json: true))
        XCTAssertThrowsError(try Options.parse(["--list-rules", "a.png"]))
        for other in [["--raw"], ["--ledger"], ["--text", "n.txt"], ["--video", "v.mp4"], ["--newest"],
                      ["--cleanshot"], ["--frames-at", "1,2"], ["--days", "3"], ["--by-mode"], ["--migrate"], ["--clipboard"]] {
            XCTAssertThrowsError(try Options.parse(["--list-rules"] + other), "\(other)")
            XCTAssertThrowsError(try Options.parse(other + ["--list-rules"]), "\(other)")
        }
        // --chapters sets the same frame times as --frames-at; the error names both.
        let meta = try file("meta.json", #"{"chapters": [{"t": 0, "title": "a"}]}"#)
        XCTAssertThrowsError(try Options.parse(["--list-rules", "--chapters", meta])) { e in
            XCTAssertTrue("\(e)".contains("--chapters"), "\(e)")
        }
        XCTAssertThrowsError(try Options.parse(["--preset"]))
        // mask: --all-rules only strengthens, so it is accepted; --preset only weakens, so it is not.
        XCTAssertTrue(try Options.parse(["mask", "--all-rules", "a.png"]).allRules)
        XCTAssertThrowsError(try Options.parse(["mask", "--preset", "secrets-only", "a.png"]))
    }

    /// Q5 A: mask is for an agent, so it ignores the rules file's switches with or without
    /// --all-rules; a person's own read honours them.
    func testMaskAlwaysRunsAllRules() throws {
        XCTAssertEqual(CLI.togglePolicy(try Options.parse(["mask", "a.png"])), .allRules)
        XCTAssertEqual(CLI.togglePolicy(try Options.parse(["mask", "--all-rules", "a.png"])), .allRules)
        XCTAssertEqual(CLI.togglePolicy(try Options.parse(["a.png"])), .honour)
        XCTAssertEqual(CLI.togglePolicy(try Options.parse(["--all-rules", "a.png"])), .allRules)
    }

    func testLedgerEntryEncodingUnchangedWithoutRulesOff() throws {
        let e = LedgerEntry(ts: "2026-11-28T00:00:00Z", mode: "image", inputs: 1, imageTokens: 10, textTokens: 2, redactions: 0)
        let s = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        XCTAssertFalse(s.contains("rules_off"), s)
        var w = e; w.rulesOff = 4
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains(#""rules_off":4"#))
    }
}
