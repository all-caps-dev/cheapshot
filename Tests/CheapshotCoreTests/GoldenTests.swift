import XCTest
@testable import CheapshotCore

/// Each Golden/cases/NN-name.txt is redacted and compared to Golden/expected/NN-name.txt.
/// A trailing newline in either file is ignored. Every case is one test failure line.
/// Inputs may hold the join marker (see Golden/README.md): it is removed before redacting,
/// so a committed case never contains a whole secret-shaped string for scanners to flag.
final class GoldenTests: XCTestCase {
    /// Swift: the fixture join marker, U+27E6 U+27E7. Never appears in real text.
    static let joinMarker = "\u{27E6}\u{27E7}"

    /// Swift: rebuild the full realistic input by deleting every join marker.
    static func assemble(_ raw: String) -> String {
        raw.replacingOccurrences(of: joinMarker, with: "")
    }

    func testGoldenCases() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let casesDir = root.appendingPathComponent("cases")
        let expectedDir = root.appendingPathComponent("expected")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertEqual(names.count, 60, "expected 60 golden cases, found \(names.count)")
        let redactor = Redactor()
        for name in names {
            let input = try String(contentsOf: casesDir.appendingPathComponent(name), encoding: .utf8)
            let expected = try String(contentsOf: expectedDir.appendingPathComponent(name), encoding: .utf8)
            let got = redactor.redact(Self.assemble(input).trimmingTrailingNewline()).text
            XCTAssertEqual(got, expected.trimmingTrailingNewline(), "golden case \(name)")
        }
    }

    /// Proves the marker is load-bearing: a marked case redacted as committed (marker left in)
    /// does not match its expected output, and the assembled input does.
    func testJoinMarkerIsStripped() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let name = "36-stripe-keys.txt"
        let raw = try String(contentsOf: root.appendingPathComponent("cases/\(name)"), encoding: .utf8)
        let expected = try String(contentsOf: root.appendingPathComponent("expected/\(name)"), encoding: .utf8)
            .trimmingTrailingNewline()
        XCTAssertTrue(raw.contains(Self.joinMarker), "\(name) should carry the join marker")
        let redactor = Redactor()
        XCTAssertNotEqual(redactor.redact(raw.trimmingTrailingNewline()).text, expected)
        XCTAssertEqual(redactor.redact(Self.assemble(raw).trimmingTrailingNewline()).text, expected)
    }
}

private extension String {
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
