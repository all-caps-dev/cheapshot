import XCTest
@testable import CheapshotPortable

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

    // The scale-suffix exclusion is anchored to image extensions: a domain that merely starts
    // with digits and an x, such as 2.5x.io, is still an address and must be redacted.
    func testEmailScaleSuffixExclusionIsAnchoredToImageExtensions() {
        XCTAssertEqual(Redactor().redact("me@2.5x.io").text, "[EMAIL]")
        XCTAssertEqual(Redactor().redact("me@2x.io").text, "[EMAIL]")
        XCTAssertEqual(Redactor().redact("icon@2.5x.png").text, "icon@2.5x.png")
        XCTAssertEqual(Redactor().redact("icon@2x.png").text, "icon@2x.png")
    }

    // Card 1862921219007841881: Vision reads dots as spaces or middle dots on tailnet addresses.
    func testIPv4WithSpacesOrMiddleDotsIsRedacted() {
        let (text, report) = Redactor().redact("peer 100 102 55 50 and 100·64·0·1 and 192.168.1.10")
        XCTAssertEqual(text, "peer [IPV4] and [IPV4] and [IPV4]")
        XCTAssertEqual(report.counts["IPV4"], 3)
        XCTAssertEqual(Redactor().redact("300 102 55 50").text, "300 102 55 50")
        XCTAssertEqual(Redactor().redact("v 1 2 3 4").text, "v 1 2 3 4")
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

    // Kaneo Fleet #319: sk-ant- keys were labelled OPENAI_KEY.
    func testAnthropicKeyGetsItsOwnLabel() {
        let (text, report) = Redactor().redact("a sk-ant-api03-Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0Pp o sk-proj-Abc123Def456Ghi789Jkl012")
        XCTAssertEqual(text, "a [ANTHROPIC_KEY] o [OPENAI_KEY]")
        XCTAssertEqual(report.counts["ANTHROPIC_KEY"], 1)
        XCTAssertEqual(report.counts["OPENAI_KEY"], 1)
    }

    // URL_CREDS must run before EMAIL, or "pass@host.com" becomes an address and the user
    // name survives in front of it.
    func testURLCredentialsBeatEmail() {
        XCTAssertEqual(Redactor().redact("redis://default:Pa55w0rd@cache.example.com:6379").text,
                       "redis://[URL_CREDS]@cache.example.com:6379")
        XCTAssertEqual(Redactor().redact("https://example.com:8443/status").text, "https://example.com:8443/status")
    }

    // A keyword value that a specific rule already replaced keeps the specific label.
    func testSecretAssignmentDefersToSpecificRules() {
        XCTAssertEqual(Redactor().redact("GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").text,
                       "GITHUB_TOKEN=[GITHUB_PAT]")
        XCTAssertEqual(Redactor().redact("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE").text, "AWS_ACCESS_KEY_ID=[AWS_KEY]")
    }

    // Hex is a secret only with a keyword: a bare digest stays readable for code screenshots.
    func testHexSecretNeedsKeyword() {
        let hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(Redactor().redact("sha256 \(hex)").text, "sha256 \(hex)")
        XCTAssertEqual(Redactor().redact("signing_key=\(hex)").text, "signing_key=[SECRET]")
    }

    // No new builtin may cross a newline (see "No rule spans a line" in the redaction docs).
    func testNewRulesStayOnOneLine() {
        let r = Redactor()
        XCTAssertEqual(r.redact("password=\nhunter22").text, "password=\nhunter22")
        XCTAssertEqual(r.redact("+44 7911\n123456").text, "+44 7911\n123456")
        XCTAssertEqual(r.redact("Basic\nYWxhZGRpbjpvcGVuc2VzYW1l").text, "Basic\nYWxhZGRpbjpvcGVuc2VzYW1l")
    }

    // Every builtin rule name is a plain token, since it lands verbatim inside [NAME].
    // 0.6.0 pre-push review: a dotted passphrase still redacts, a spaced address right after a
    // 0 column is still tried from its own first octet, and a quoted Cookie value is covered.
    func testReleaseReviewRedactionGaps() {
        XCTAssertEqual(Redactor().redact("password: correct.horse.battery").text, "password: [SECRET]")
        XCTAssertEqual(Redactor().redact("0 192 168 1 20").text, "0 [IPV4]")
        XCTAssertEqual(Redactor().redact("00 192 168 1 20").text, "00 [IPV4]")
        // Release review: keys with one digit or none are still keys; CSS classes are not.
        XCTAssertEqual(Redactor().redact("Your key sk-live-phwfvcajkbjyn3mgwsiu").text, "Your key [OPENAI_KEY]")
        XCTAssertEqual(Redactor().redact("key sk-abcdefghijklmnopqrstuvwx").text, "key [OPENAI_KEY]")
        XCTAssertEqual(Redactor().redact(".sk-cube-grid-container-wrapper { }").text, ".sk-cube-grid-container-wrapper { }")
        XCTAssertEqual(Redactor().redact("pass: data.center.rocks").text, "pass: [SECRET]")
        XCTAssertEqual(Redactor().redact("viewBox=\"0 0 24 24\"").text, "viewBox=\"0 0 24 24\"")
        XCTAssertEqual(
            Redactor().redact("\"cookie\": \"sid=347301ef56e64dc3cd6089065c3146e8; theme=dark\"").text,
            "\"cookie\": \"sid=[SECRET]; theme=dark\"")
    }

    func testBuiltinNamesArePlainTokens() {
        for rule in Rule.builtin {
            XCTAssertTrue(rule.name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }, rule.name)
        }
    }

    // Review finding 3: retryShorter takes the longest valid prefix at a separator; a rule
    // without it still drops the whole hit.
    func testRetryShorterKeepsLongestValidPrefix() {
        let even: @Sendable (String) -> Bool = { $0.filter(\.isNumber).count % 2 == 0 }
        let retry = Rule(name: "N", pattern: #"\d+(?: \d+)*"#, options: [], validator: even, retryShorter: true)
        let plain = Rule(name: "N", pattern: #"\d+(?: \d+)*"#, options: [], validator: even)
        XCTAssertEqual(Redactor(rules: [retry]).redact("12 34 5").text, "[N] 5")
        XCTAssertEqual(Redactor(rules: [plain]).redact("12 34 5").text, "12 34 5")
    }

    // Review findings 1 and 5 at the redactor level, on one JSON line as the API returns it.
    func testUsageCountsSurviveOnOneLine() {
        let line = #"{"input_tokens": 123456, "cache_creation_input_tokens": 2048000, "max_tokens": 100000}"#
        XCTAssertEqual(Redactor().redact(line).text, line)
    }

    // Every builtin must stay linear on long input: no catastrophic backtracking. Each shape
    // targets one rule's repeats (TOKEN, SECRET, URL_CREDS, IBAN, PHONE, EMAIL).
    func testBuiltinsFinishFastOnHundredThousandCharacterLines() {
        let n = 100_000
        let shapes: [String] = [
            String(repeating: "a", count: n),
            String(repeating: "A", count: n),
            String(repeating: "aB3", count: n / 3),
            "password=" + String(repeating: "x", count: n),
            "password=\"" + String(repeating: "a,", count: n / 2),
            "token_count: " + String(repeating: "1", count: n),
            "postgres://u:" + String(repeating: "a@b", count: n / 3),
            "postgres://u:" + String(repeating: "a", count: n),
            "BE68" + String(repeating: " 1234", count: n / 5),
            "+44" + String(repeating: " 1", count: n / 2),
            String(repeating: "a.", count: n / 2) + "@",
            String(repeating: "1 ", count: n / 2),
            // Post-merge review F3: these four were quadratic (10 to 16 s at 100,000 characters).
            String(repeating: "eyJaaaaaaaa-", count: n / 12),
            String(repeating: "://a:b", count: n / 6),
            String(repeating: "x://a:bb,", count: n / 9),
            String(repeating: "://a:b@_", count: n / 8),
            String(repeating: "pass_", count: n / 5),
            // Shapes for the 0.6.0 flag, header and cookie rules.
            String(repeating: "--password x ", count: n / 13),
            String(repeating: "sshpass -a ", count: n / 11),
            String(repeating: "mysql -u r ", count: n / 11),
            String(repeating: "curl -u a:b ", count: n / 12),
            String(repeating: "Authorization: ", count: n / 15),
            "Cookie: " + String(repeating: "a=b; ", count: n / 5),
            "password" + String(repeating: "\t", count: n),
            String(repeating: "password\t \t", count: n / 11),
            // NOV-161: values scanned again after an empty field. Chains of keys, keys with
            // prefixes, an overlapping value, and a long numeric tail after a password key.
            String(repeating: "secrets: password: ", count: n / 19),
            String(repeating: "token: ", count: n / 7),
            String(repeating: "a_password:\t", count: n / 12),
            String(repeating: "pass: pass ", count: n / 11),
            "password: " + String(repeating: "token:", count: n / 6),
            "secrets:" + String(repeating: " ", count: 40) + "password: " + String(repeating: "1", count: n),
            String(repeating: "secrets:  MyPassword: ", count: n / 22),
            // NOV-161: URL_CREDS has no length cap now. One valid long password, many starts
            // with no host, hosts that are too long, bracket hosts that never close, many '@',
            // and the JSON shape that leaked (two credential URLs per object).
            "postgres://u:" + String(repeating: "a", count: n) + "@h",
            String(repeating: "://u:@", count: n / 6),
            String(repeating: "x://u:p@h,", count: n / 10),
            String(repeating: "://u:p@" + String(repeating: "a", count: 260), count: n / 267),
            "://u:" + String(repeating: "@[" + String(repeating: ":", count: 70), count: n / 72),
            "://u:" + String(repeating: "@a", count: n / 2),
            String(repeating: #"{"a":"postgres://u:pw@h1","b":"mysql://u:pw@h2"},"#, count: n / 50),
            String(repeating: "://a:b\"", count: n / 7),
            // Fable review of 801ab86: values scanned again (refused nesting, keys inside long or
            // quoted values, alternating quotes), real and fake closers, escaped quotes, long
            // usernames with no length cap.
            "token: " + String(repeating: "process.env.token=", count: n / 18),
            String(repeating: "token=process.env.", count: n / 18),
            String(repeating: "password: " + String(repeating: "a1", count: 70) + "token: x1y2z3w4 ", count: n / 170),
            String(repeating: #"password: "prod, token": "#, count: n / 26),
            "password: '" + String(repeating: "\"token: '", count: n / 10),
            String(repeating: "pass: pass:x", count: n / 12),
            String(repeating: "(pg://u:p@ss)w", count: n / 14),
            String(repeating: #""pg://u:p@ss\"w","#, count: n / 18),
            String(repeating: "(a://b:c@d)\"e://f:g@h\"<i://j:k@l>`m://n:o@p`'q://r:s@t'", count: n / 55),
            String(repeating: "('\"<`x://u:", count: n / 11),
            "pg://" + String(repeating: "u", count: n),
            String(repeating: "x://" + String(repeating: "u", count: 200), count: n / 204),
            String(repeating: "(x://u:1", count: n / 8),
            // CS-05 gap 4: fence lines (builtins never take the fence-free second reading, so
            // these must cost what the same text without fences costs). Many fence lines, many
            // hits between them, one huge fence line, backtick runs that are not fences, and a
            // heavy shape inside a fence.
            String(repeating: "```\n", count: n / 4),
            String(repeating: "a@b.io\n```\n", count: n / 11),
            String(repeating: "~", count: n),
            String(repeating: "```a`\n", count: n / 6),
            "```\n" + String(repeating: "token: ", count: n / 7) + "\n```",
        ]
        let redactor = Redactor()
        var slowest = (0.0, "")
        // Liveness: a regex that gives up on a shape is fast and redacts nothing after it, so
        // every shape is followed by a password line that must still be redacted.
        let marker = "Zq9kQ2" + "mW7p"
        // A runaway regex takes seconds to minutes (the F3 shapes took 10 to 16 s), so the limits
        // below still catch one while leaving room for slow CI runners. The iOS Simulator is
        // several times slower than macOS (PR #22: 1.36 s and 2.25 s for two shapes against a
        // 1.0 s limit), so it gets 3.0 s. macOS runners are noisy too: this test failed on
        // macos-latest at 1.06 s, 1.15 s and 1.007 s against the old 1.0 s limit, so macOS and
        // devices get 2.0 s.
        // Windows Foundation's regex is 4 to 8 times slower on these lines (PR #23's windows-core
        // runs: 3.7 s to 8.2 s across 9 shapes, then 11.01 s on 9986031), so Windows gets 20 s.
        #if targetEnvironment(simulator)
        let limit = 3.0
        #elseif os(Windows)
        let limit = 20.0
        #else
        let limit = 2.0
        #endif
        for shape in shapes {
            let start = Date()
            let out = redactor.redact(shape + "\npassword=" + marker).text
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, limit, "\(shape.prefix(16))... took \(elapsed)s (limit \(limit)s)")
            XCTAssertTrue(out.hasSuffix("\npassword=[SECRET]"), "\(shape.prefix(16))... stopped redacting")
            if elapsed > slowest.0 { slowest = (elapsed, String(shape.prefix(24))) }
        }
        print("slowest 100k shape: \(slowest.1.debugDescription) \(String(format: "%.3f", slowest.0))s")
    }
    // CS-05 gap 4: a two-line custom rule still matches when a code-fence line sits between its
    // two lines, as `Layout.text` puts one after a fenced line. Fences of every shape, a
    // surrogate pair before the hit (UTF-16 offsets), and a rule that targets fences itself.
    func testCustomRuleSeesPastCodeFences() throws {
        let hex = "b1946ac924" + "92d2347f2a"
        let json = try JSONSerialization.data(withJSONObject: [
            ["name": "MYCREDS", "pattern": #"creds-begin\n[0-9a-f]{20}"#],
            ["name": "CODEBLOCK", "pattern": #"(?s)~~~~.*?~~~~"#],
            ["name": "FOOPW", "pattern": #"foo\npassword"#],
            ["name": "AFTER", "pattern": #"(?<=after-marker\n)[0-9a-f]{20}"#],
        ])
        let r = Redactor(customRules: try RuleFile.parse(json))
        func line(_ n: Int, _ text: String, fenced: Bool) -> RenderedLine {
            RenderedLine(n: n, text: text, bbox: .zero, confidence: 1, fenced: fenced)
        }
        let laidOut = r.redact(Layout.text([line(1, "creds-begin", fenced: true), line(2, hex, fenced: false)]))
        XCTAssertEqual(laidOut.text, "```\n[MYCREDS]")
        XCTAssertEqual(laidOut.report.counts["MYCREDS"], 1)
        XCTAssertEqual(r.redact("```swift\n\u{1F511} creds-begin\n```\n\(hex) tail").text, "```swift\n\u{1F511} [MYCREDS] tail")
        XCTAssertEqual(r.redact("creds-begin\r\n  ~~~\r\n```\n\(hex)").text, "creds-begin\r\n  ~~~\r\n```\n\(hex)",
                       "a CR before the newline is not part of the rule, so it does not match either way")
        XCTAssertEqual(r.redact("creds-begin\n  ~~~ text\r\n```\n\(hex)").text, "[MYCREDS]")
        // Not fences: four spaces of indent, two backticks, a backtick after the run.
        for notFence in ["    ```", "``", "```a`b"] {
            XCTAssertEqual(r.redact("creds-begin\n\(notFence)\n\(hex)").text, "creds-begin\n\(notFence)\n\(hex)")
        }
        // A rule that matches the fences themselves still does, counted once.
        let block = r.redact("a\n~~~~\npassword-less text\n~~~~\nb")
        XCTAssertEqual(block.text, "a\n[CODEBLOCK]\nb")
        XCTAssertEqual(block.report.counts["CODEBLOCK"], 1)
        // A hit inside a fenced block, which both readings see, is replaced and counted once.
        let hexRule = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
            ["name": "HEX", "pattern": "[0-9a-f]{20}"],
        ])))
        let inside = hexRule.redact("```\n\(hex)\n```")
        XCTAssertEqual(inside.text, "```\n[HEX]\n```")
        XCTAssertEqual(inside.report.counts["HEX"], 1)
        // The fence-free reading runs after the builtins, so a custom rule that crosses a fence
        // to eat a builtin's cue (`password`) cannot bring the builtin's value back.
        let cue = r.redact("foo\n```\npassword: hunter2abc9").text
        XCTAssertFalse(cue.contains("hunter2abc9"), cue.debugDescription)
        XCTAssertEqual(cue, "[FOOPW]: [SECRET]")
        // A rule that only looks across the fence (a lookbehind) is caught too, and the fence
        // line stays because the hit does not cover it.
        XCTAssertEqual(r.redact("```\nafter-marker\n```\n\(hex)").text, "```\nafter-marker\n```\n[AFTER]")
    }

    // The fence-free reading for a custom rule stays linear on fence-heavy input: many fence
    // lines, each crossed by a hit.
    func testCustomRuleAcrossManyFencesIsFast() throws {
        let r = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
            ["name": "PAIR", "pattern": #"k\nv"#],
        ])))
        let n = 100_000
        let text = String(repeating: "k\n```\nv\n", count: n / 8)
        let start = Date()
        let out = r.redact(text)
        let elapsed = Date().timeIntervalSince(start)
        #if os(Windows)
        let limit = 20.0
        #elseif targetEnvironment(simulator)
        let limit = 3.0
        #else
        let limit = 2.0
        #endif
        XCTAssertLessThan(elapsed, limit, "took \(elapsed)s")
        XCTAssertEqual(out.report.counts["PAIR"], n / 8)
        XCTAssertFalse(out.text.contains("k\n"))
    }

    // The fence-free second reading must not change what the builtins do: every golden case
    // with a fence line before, between and after each of its lines redacts to its expected
    // output once the fence lines are taken back out.
    func testBuiltinsRedactTheSameAcrossFences() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cases").path)
            .filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertFalse(names.isEmpty)
        let redactor = Redactor()
        func chomp(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
        for name in names {
            let input = chomp(GoldenTests.assemble(try String(contentsOf: root.appendingPathComponent("cases/\(name)"), encoding: .utf8)))
            let expected = chomp(try String(contentsOf: root.appendingPathComponent("expected/\(name)"), encoding: .utf8))
            let fenced = (["```"] + input.components(separatedBy: "\n").flatMap { [$0, "```"] }).joined(separator: "\n")
            let result = redactor.redact(fenced)
            let out = result.text.components(separatedBy: "\n").filter { $0 != "```" }
            XCTAssertEqual(out.joined(separator: "\n"), expected, "golden case \(name) inside fences")
            XCTAssertEqual(result.report, redactor.redact(input).report, "golden case \(name) counts inside fences")
        }
    }

    // CS-05 gap 4, review fix: a custom rule reads the same text across a fence as without one.
    // Its first-line cue here is also a builtin's (PRIVATE_KEY), and the builtins run after the
    // custom rules, so a reading that waited for them saw `[PRIVATE_KEY]` and left the key body.
    // Secret-shaped strings are joined at runtime (GoldenTests.joinMarker), as elsewhere.
    func testCustomRuleBeatsBuiltinThatTakesItsCueAcrossAFence() throws {
        let m = GoldenTests.joinMarker
        let header = GoldenTests.assemble("-----BEGIN RSA PRIVATE" + m + " KEY-----")
        let body = GoldenTests.assemble("MIIEowIBAAKCAQ" + m + "EAxyz123456")
        let r = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
            ["name": "KEYBODY", "pattern": #"-----BEGIN [A-Z ]*PRIVATE KEY-----\n[A-Za-z0-9+/=]{20,}"#],
        ])))
        let plain = r.redact(header + "\n" + body)
        XCTAssertEqual(plain.text, "[KEYBODY]", "control: without a fence the custom rule wins")
        for fence in ["```", "~~~ text", "```\n```"] {
            let fenced = r.redact(header + "\n" + fence + "\n" + body)
            XCTAssertFalse(fenced.text.contains(body), "key body leaked past \(fence.debugDescription): \(fenced.text.debugDescription)")
            // Same text and same counts as without the fence: the PRIVATE_KEY token the builtin
            // placed is folded into KEYBODY's, and its count goes with it.
            XCTAssertEqual(fenced.text, plain.text)
            XCTAssertEqual(fenced.report, plain.report)
        }
        // Through the layout that puts the fence there: a fenced header line, then the body.
        func line(_ n: Int, _ text: String, fenced: Bool) -> RenderedLine {
            RenderedLine(n: n, text: text, bbox: .zero, confidence: 1, fenced: fenced)
        }
        let laidOut = r.redact(Layout.text([line(1, header, fenced: true), line(2, body, fenced: false)])).text
        XCTAssertFalse(laidOut.contains(body), laidOut.debugDescription)
    }

    // CS-05 gap 4, second review fix: a rule whose second part also matches a fence line
    // (`\S+`, `.+`, `.*`) takes the fence as its next line in the plain pass. The fence-free
    // reading comes from the same text as the plain hits, before they are replaced, so it still
    // reaches the body after the fence.
    func testCustomRuleWhoseNextLineMatchesAFenceStillReachesPastIt() throws {
        let m = GoldenTests.joinMarker
        let header = GoldenTests.assemble("-----BEGIN RSA PRIVATE" + m + " KEY-----")
        let body = GoldenTests.assemble("MIIEowIBAAKCAQ" + m + "EAxyz123456")
        for pattern in [#"\S+"#, ".+", ".*"] {
            let r = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
                ["name": "KEYBODY", "pattern": #"-----BEGIN [A-Z ]*PRIVATE KEY-----\n"# + pattern],
            ])))
            let plain = r.redact(header + "\n" + body)
            XCTAssertEqual(plain.text, "[KEYBODY]", "control for \(pattern): without a fence the rule takes the body")
            for fence in ["```", "```swift", "~~~"] {
                let fenced = r.redact(header + "\n" + fence + "\n" + body)
                XCTAssertFalse(fenced.text.contains(body),
                               "\(pattern) past \(fence.debugDescription): \(fenced.text.debugDescription)")
                XCTAssertEqual(fenced.text, plain.text, "\(pattern) past \(fence.debugDescription)")
                XCTAssertEqual(fenced.report, plain.report, "\(pattern) past \(fence.debugDescription)")
            }
        }
    }

    // CS-05 gap 4, review fix: the same with EMAIL eating the cue of a custom rule, and the
    // guard for the other direction: the early reading's hits are replaced last, so a custom
    // rule crossing a fence never takes a builtin's cue (`password`) away before that builtin
    // has read it.
    func testCustomRuleBeatsEmailCueAcrossAFenceAndKeepsBuiltinCues() throws {
        let m = GoldenTests.joinMarker
        let password = GoldenTests.assemble("Hunter2" + m + "Hunter2!!")
        let value = GoldenTests.assemble("hunter2" + m + "abc9")
        let r = Redactor(customRules: try RuleFile.parse(try JSONSerialization.data(withJSONObject: [
            ["name": "CORPPW", "pattern": #"[\w.]+@corp\.com\n\S{12,}"#],
            ["name": "FOOPW", "pattern": #"foo\npassword"#],
            ["name": "WIDE", "pattern": #"login\n[\w.]+@corp\.com"#],
        ])))
        XCTAssertEqual(r.redact("alice@corp.com\n" + password).text, "[CORPPW]", "control: no fence")
        let fenced = r.redact("alice@corp.com\n```\n" + password)
        XCTAssertFalse(fenced.text.contains(password), fenced.text.debugDescription)
        XCTAssertEqual(fenced.text, "[CORPPW]")
        XCTAssertEqual(fenced.report.counts, ["CORPPW": 1])
        // FOOPW guard: the builtin SECRET still reads `password: ...` and replaces the value.
        let cue = r.redact("foo\n```\npassword: " + value)
        XCTAssertFalse(cue.text.contains(value), cue.text.debugDescription)
        XCTAssertEqual(cue.text, "[FOOPW]: [SECRET]")
        XCTAssertEqual(cue.report.counts, ["FOOPW": 1, "SECRET": 1])
        // Two early hits that overlap (WIDE and CORPPW share the address) become one token, and
        // neither the address nor the password is left.
        let both = r.redact("login\n```\nalice@corp.com\n~~~\n" + password + " tail").text
        XCTAssertFalse(both.contains(password) || both.contains("alice"), both.debugDescription)
        XCTAssertEqual(both, "[WIDE] tail")
    }
}
