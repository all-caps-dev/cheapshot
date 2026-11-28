// Apple platforms only: XCTExpectFailure is Apple XCTest only (swift-corelibs-xctest, used on
// Windows and Linux, has none). These
// are expected-failure gap markers, not part of the gated redaction count (PR #23 moved them here
// with GoldenTests, whose joinMarker they use).
#if canImport(Darwin)
import XCTest
@testable import CheapshotPortable

/// CS-05: tests for the redaction gaps the v0.6.0 reviews found. Where a gap is still open, its
/// assertion is wrapped in `XCTExpectFailure(strict: true)`, so
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

    // Gap 3, closed as intended behaviour (product decision, 2026-11-28): the
    // unquoted value class in the SECRET assignment contains ".", so `TOKEN=Kk...5.` redacts as
    // `TOKEN=[SECRET]` and the sentence loses its period. That stays: a password can end in ".",
    // and handing the character back would show it. A miss is worse than lost punctuation.
    func testTokenValueTakesSentencePeriodInside() {
        let value = Self.assemble("Kk3Mm9" + Self.m + "Qq2Ww5")
        XCTAssertEqual(Redactor().redact("TOKEN=\(value) ok").text, "TOKEN=[SECRET] ok")
        XCTAssertEqual(Redactor().redact("TOKEN=\(value).").text, "TOKEN=[SECRET]")
        XCTAssertEqual(Redactor().redact("password: \(value). Next").text, "password: [SECRET] Next")
    }

    // Gap 3b, CHE-20's own wording, still open: a value named in prose with no separator after
    // the keyword ("the token is abc...", no `=`, `:` or lone tab) is not redacted, with or
    // without the period. SECRET needs a separator after the keyword, and the TOKEN catch-all
    // needs 20 or more characters with both cases. The period plays no part: each form has its
    // own strict wrapper, so a fix for one form alone turns that one red. Behaviour is unchanged
    // until a fix is picked. Confirmed red 2026-11-28.
    func testTokenNamedInProseWithoutSeparatorIsRedacted() {
        let value = Self.assemble("abc123" + Self.m + "xyz")
        // Control: the same value after a separator is caught, with and without the period.
        XCTAssertEqual(Redactor().redact("token: \(value).").text, "token: [SECRET]")
        XCTAssertEqual(Redactor().redact("token: \(value)").text, "token: [SECRET]")
        for s in ["the token is \(value).", "the token is \(value)"] {
            XCTExpectFailure("CS-05 gap 3b: a token named in prose with no separator is kept", strict: true) {
                let out = Redactor().redact(s).text
                XCTAssertFalse(out.contains(value), "the value should not survive: \(out.debugDescription)")
            }
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

    // Gap 5: OPENAI_KEY's validator vetoes any sk- key of short lowercase words joined by
    // hyphens, the shape it uses to spare CSS classes, so a real key of that shape survives
    // (no other builtin reads it: the catch-all needs an uppercase letter). Confirmed red
    // today, 2026-11-27.
    func testSkKeyOfShortLowercaseWordsIsRedacted() {
        let key = Self.assemble("sk-my-super-secret" + Self.m + "-litellm-key")
        // Control: a key of about the same length that is not lowercase words is caught by
        // OPENAI_KEY, so the expected failure below is the word veto, not the rule itself.
        let mixed = Self.assemble("sk-Ab3dEf6Hh9" + Self.m + "Kk2Ll5Oo8Pp1Qq")
        XCTAssertEqual(Redactor().redact("Your key \(mixed)").text, "Your key [OPENAI_KEY]")
        XCTExpectFailure("CS-05 gap 5: the CSS-class veto also refuses lowercase-word keys", strict: true) {
            let out = Redactor().redact("Your key \(key)").text
            XCTAssertFalse(out.contains(key), "the sk- key should not survive: \(out.debugDescription)")
            XCTAssertFalse(out.contains("sk-my") || out.contains("litellm"), "no part of the sk- key should survive: \(out.debugDescription)")
        }
    }
}
#endif
