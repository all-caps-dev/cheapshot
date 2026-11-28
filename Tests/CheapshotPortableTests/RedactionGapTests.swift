// Apple platforms only: XCTExpectFailure is Apple XCTest only (swift-corelibs-xctest, used on
// Windows and Linux, has none). These
// are expected-failure gap markers, not part of the gated redaction count (PR #23 moved them here
// with GoldenTests, whose joinMarker they use).
#if canImport(Darwin)
import XCTest
@testable import CheapshotPortable

/// CS-05: one test per redaction gap the v0.6.0 reviews found. Where a gap is still open, its
/// assertion is wrapped in `XCTExpectFailure(strict: true)` where it fails today, so
/// the suite is green now and the test turns red, on purpose, once the gap is fixed (the
/// wrapper then reports that no expected failure occurred and the wrap is removed).
///
/// Each red gap also has a plain control assertion outside the wrapper: the same secret in a
/// nearby input the redactor does catch. That pins the expected failure to the gap itself, not
/// to a fixture the rule would refuse anyway.
///
/// Every fake secret below is committed as parts joined with `GoldenTests.joinMarker` and
/// assembled at runtime, so no whole secret-shaped string sits in the file.
final class RedactionGapTests: XCTestCase {
    private static let m = GoldenTests.joinMarker
    private static func assemble(_ raw: String) -> String { GoldenTests.assemble(raw) }

    // Gap 1: an empty first pair stops the Cookie chain. The first-pair branch needs at least
    // one value character after `foo=`, so nothing matches on the line, and the `;`-chained
    // branch (\G, the end of the previous match) never starts: the sid value is left in the
    // clear. Confirmed red today, 2026-11-27.
    func testCookieHeaderWithEmptyFirstPairRedactsSid() {
        let sid = Self.assemble("7f3a9c21d04e" + Self.m + "b85a6f31c2d9")
        // Control: with a non-empty first pair the chain reaches sid.
        XCTAssertEqual(Redactor().redact("Cookie: foo=bar; sid=\(sid)").text, "Cookie: foo=bar; sid=[SECRET]")
        XCTExpectFailure("CS-05 gap 1: an empty first Cookie pair stops the chain", strict: true) {
            let out = Redactor().redact("Cookie: foo=; sid=\(sid)").text
            XCTAssertFalse(out.contains(sid), "the sid value should not survive: \(out.debugDescription)")
        }
    }

    // Gap 2: a key reached through a `this.` / `self.` / `config.` prefix. The keyword match
    // starts at `apiKey` and reads forward, so the prefix is transparent. This case already
    // passes today, so it stays a plain regression test over all three prefixes, on both
    // paths: a full-length key (OPENAI_KEY) and a short one OPENAI_KEY's 20-character floor
    // skips, which only the SECRET keyword assignment can catch.
    // Not covered here (the card names the key prefix): a VALUE that starts with one of these
    // prefixes, such as `password = "this.is.my.passw0rd"`, is still kept by the
    // `codeReferencePrefixes` veto in Validators.secretValue (a known gap noted there).
    func testKeyAssignedThroughObjectPrefixIsRedacted() {
        let longKey = Self.assemble("sk-proj-Ab3dEf6Hh9" + Self.m + "Kk2Ll5Oo8Pp1")
        let shortKey = Self.assemble("sk-Ab3d" + Self.m + "Ef6Hh9")
        for prefix in ["this", "self", "config"] {
            XCTAssertEqual(Redactor().redact("\(prefix).apiKey = \"\(longKey)\"").text,
                           "\(prefix).apiKey = \"[OPENAI_KEY]\"")
            XCTAssertEqual(Redactor().redact("\(prefix).apiKey = \"\(shortKey)\"").text,
                           "\(prefix).apiKey = \"[SECRET]\"")
        }
    }

    // Gap 3: the unquoted value class in the SECRET assignment contains ".", so the value
    // match swallows a sentence-final period: `TOKEN=Kk...5.` redacts as `TOKEN=[SECRET]` and
    // the sentence loses its period. The value must go while the period may stay. Confirmed
    // red today (the period is consumed), 2026-11-27.
    func testTokenValueKeepsSentencePeriod() {
        let value = Self.assemble("Kk3Mm9" + Self.m + "Qq2Ww5")
        // Control: the value itself is redacted; only the period is lost.
        XCTAssertEqual(Redactor().redact("TOKEN=\(value) ok").text, "TOKEN=[SECRET] ok")
        XCTExpectFailure("CS-05 gap 3: the value match swallows the sentence period", strict: true) {
            let out = Redactor().redact("TOKEN=\(value).").text
            XCTAssertEqual(out, "TOKEN=[SECRET].")
        }
    }

    // Gap 4: the text field path. Runner builds `Redactor(customRules: RuleFile.load(...))` and
    // redacts `Layout.text(rendered)`, which puts a ``` fence line between a fenced line and the
    // unfenced line after it, so a custom rule whose pattern spans those two lines no longer
    // matches and its secret survives every rule (a bare lowercase hex run is invisible to the
    // built-ins). The rule is parsed from rules-file JSON so it is exactly what a user's
    // --rules file produces. Confirmed red today, 2026-11-27.
    func testTwoLineCustomRuleAcrossCodeFenceRedacts() throws {
        let secret = Self.assemble("b1946ac924" + Self.m + "92d2347f2a")
        let json = try JSONSerialization.data(withJSONObject: [
            ["name": "MYCREDS", "pattern": #"creds-begin\n[0-9a-f]{20}"#],
        ])
        let redactor = Redactor(customRules: try RuleFile.parse(json))
        func line(_ n: Int, _ text: String, fenced: Bool) -> RenderedLine {
            RenderedLine(n: n, text: text, bbox: .zero, confidence: 1, fenced: fenced)
        }
        // Control: with neither line fenced, the two-line rule redacts the secret.
        let plain = redactor.redact(Layout.text([line(1, "creds-begin", fenced: false),
                                                 line(2, secret, fenced: false)])).text
        XCTAssertFalse(plain.contains(secret), "control: the rule should match unfenced lines: \(plain.debugDescription)")
        let fencedText = Layout.text([line(1, "creds-begin", fenced: true), line(2, secret, fenced: false)])
        XCTExpectFailure("CS-05 gap 4: a fence line breaks a two-line custom rule", strict: true) {
            let out = redactor.redact(fencedText).text
            XCTAssertFalse(out.contains(secret),
                           "the two-line rule should see past the fence: \(out.debugDescription)")
        }
    }

    // Gap 5, fixed: OPENAI_KEY's validator vetoes any sk- key of short lowercase words joined
    // by hyphens, the shape it uses to spare CSS classes, so a real key of that shape survived.
    // A second OPENAI_KEY rule, after the SECRET rules, now takes the same shape with no veto
    // right after a key word ("key", "token", camelCase `openaiKey`); a bare CSS class, or one
    // in a class list, is still spared. With a separator SECRET takes it first. Golden case 64 covers it
    // on every platform.
    func testSkKeyOfShortLowercaseWordsIsRedacted() throws {
        let key = Self.assemble("sk-my-super-secret" + Self.m + "-litellm-key")
        // Control: a key of about the same length that is not lowercase words is caught by
        // OPENAI_KEY with no key word at all.
        let mixed = Self.assemble("sk-Ab3dEf6Hh9" + Self.m + "Kk2Ll5Oo8Pp1Qq")
        XCTAssertEqual(Redactor().redact("Here \(mixed)").text, "Here [OPENAI_KEY]")
        let out = Redactor().redact("Your key \(key)").text
        XCTAssertFalse(out.contains(key), "the sk- key should not survive: \(out.debugDescription)")
        XCTAssertFalse(out.contains("sk-my") || out.contains("litellm"), "no part of the sk- key should survive: \(out.debugDescription)")
        XCTAssertEqual(out, "Your key [OPENAI_KEY]")
        // Still spared with no key word: a CSS class of the same shape.
        XCTAssertEqual(Redactor().redact(".sk-cube-grid-container-wrapper { }").text, ".sk-cube-grid-container-wrapper { }")
        // The placeholder guard lists builtin names by hand. Every builtin that runs before the
        // key-context rule can leave its `[NAME]` right before a CSS class; none of them may read
        // as a key word, so a builtin added above the rule without joining the list fails here.
        let rules = Rule.builtin
        let keyContext = try XCTUnwrap(rules.firstIndex { $0.pattern.hasPrefix(#"\b(?=sk-)"#) })
        for name in Set(rules[..<keyContext].map(\.name)) {
            let line = "[\(name)] sk-cube-grid-container-wrapper"
            XCTAssertEqual(Redactor().redact(line).text, line, "[\(name)] should not read as a key word")
        }
        // A bracketed label no builtin writes is the user's text and still counts as a key word.
        XCTAssertEqual(Redactor().redact("[API_KEY] \(key)").text, "[API_KEY] [OPENAI_KEY]")
    }
}
#endif
