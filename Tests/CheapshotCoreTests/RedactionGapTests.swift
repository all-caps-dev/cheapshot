import XCTest
@testable import CheapshotCore

/// CS-05: one test per redaction gap the v0.6.0 reviews found. The redactor is unchanged here;
/// each gap's assertion is wrapped in `XCTExpectFailure(strict: true)` where it fails today, so
/// the suite is green now and the test turns red, on purpose, once the gap is fixed (the
/// wrapper then reports that no expected failure occurred and the wrap is removed).
///
/// Every fake secret below is committed as parts joined with `joinMarker` and assembled at
/// runtime, so no whole secret-shaped string sits in the file (GoldenTests convention).
final class RedactionGapTests: XCTestCase {
    /// The fixture join marker, U+27E6 U+27E7. Never appears in real text.
    static let joinMarker = "\u{27E6}\u{27E7}"

    /// Rebuild the full realistic string by deleting every join marker.
    static func assemble(_ raw: String) -> String {
        raw.replacingOccurrences(of: Self.joinMarker, with: "")
    }

    // Gap 1: an empty first pair stops the Cookie chain. The first-pair branch needs at least
    // one value character after `foo=`, so nothing matches on the line, and the `;`-chained
    // branch (\G, the end of the previous match) never starts: the sid value is left in the
    // clear. Confirmed red today, 2026-11-27.
    func testCookieHeaderWithEmptyFirstPairRedactsSid() {
        let sid = Self.assemble("7f3a9c21d04e" + Self.joinMarker + "b85a6f31c2d9")
        XCTExpectFailure("CS-05 gap 1: an empty first Cookie pair stops the chain", strict: true) {
            let out = Redactor().redact("Cookie: foo=; sid=\(sid)").text
            XCTAssertEqual(out, "Cookie: foo=; sid=[SECRET]")
        }
    }

    // Gap 2: a key reached through a `this.` / `self.` / `config.` prefix. The keyword match
    // starts at `apiKey` and reads forward, so the prefix is transparent and the quoted value
    // redacts through OPENAI_KEY. This case already passes today, so it stays a plain
    // regression test over all three prefixes.
    func testKeyAssignedThroughObjectPrefixIsRedacted() {
        let key = Self.assemble("sk-proj-Ab3dEf6Hh9Kk2Ll5" + Self.joinMarker + "Oo8Pp1")
        for prefix in ["this", "self", "config"] {
            let out = Redactor().redact("\(prefix).apiKey = \"\(key)\"").text
            XCTAssertEqual(out, "\(prefix).apiKey = \"[OPENAI_KEY]\"")
        }
    }

    // Gap 3: the unquoted value class in the SECRET assignment contains ".", so the value
    // match swallows a sentence-final period: `TOKEN=Kk...5.` redacts as `TOKEN=[SECRET]` and
    // the sentence loses its period. The value must go while the period may stay. Confirmed
    // red today (the period is consumed), 2026-11-27.
    func testTokenValueKeepsSentencePeriod() {
        let value = Self.assemble("Kk3Mm9" + Self.joinMarker + "Qq2Ww5")
        XCTExpectFailure("CS-05 gap 3: the value match swallows the sentence period", strict: true) {
            let out = Redactor().redact("TOKEN=\(value).").text
            XCTAssertEqual(out, "TOKEN=[SECRET].")
        }
    }

    // Gap 4: the text-field path (Layout.text) puts a ``` fence line between a fenced line and
    // the unfenced line after it, so a custom rule whose pattern spans those two lines no
    // longer matches and its secret survives every rule (a bare lowercase hex run is invisible
    // to the built-ins). Confirmed red today, 2026-11-27.
    func testTwoLineCustomRuleAcrossCodeFenceRedacts() {
        let secret = Self.assemble("b1946ac924" + Self.joinMarker + "92d2347f2a")
        let lines = [
            RenderedLine(n: 1, text: "creds-begin", bbox: .zero, confidence: 1, fenced: true),
            RenderedLine(n: 2, text: secret, bbox: .zero, confidence: 1, fenced: false),
        ]
        let rule = Rule(name: "MYCREDS", pattern: "creds-begin\n(\(secret))",
                        options: [], replacesCaptureGroup: true)
        XCTExpectFailure("CS-05 gap 4: a fence line breaks a two-line custom rule", strict: true) {
            let out = Redactor(customRules: [rule]).redact(Layout.text(lines)).text
            XCTAssertFalse(out.contains(secret),
                           "the two-line rule should see past the fence: \(out.debugDescription)")
        }
    }

    // Gap 5: OPENAI_KEY's validator vetoes any sk- key of short lowercase words joined by
    // hyphens, the shape it uses to spare CSS classes, so a real key of that shape survives
    // (no other builtin reads it: the catch-all needs an uppercase letter). Confirmed red
    // today, 2026-11-27.
    func testSkKeyOfShortLowercaseWordsIsRedacted() {
        let key = Self.assemble("sk-my-super-secret" + Self.joinMarker + "-litellm-key")
        XCTExpectFailure("CS-05 gap 5: the CSS-class veto also refuses lowercase-word keys", strict: true) {
            let out = Redactor().redact("Your key \(key)").text
            XCTAssertEqual(out, "Your key [OPENAI_KEY]")
        }
    }
}
