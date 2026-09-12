import XCTest
@testable import CheapshotCore

/// Each Golden/cases/NN-name.txt is redacted and compared to Golden/expected/NN-name.txt.
/// A trailing newline in either file is ignored. Every case is one test failure line.
final class GoldenTests: XCTestCase {
    func testGoldenCases() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let casesDir = root.appendingPathComponent("cases")
        let expectedDir = root.appendingPathComponent("expected")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertEqual(names.count, 33, "expected 33 golden cases, found \(names.count)")
        let redactor = Redactor()
        for name in names {
            let input = try String(contentsOf: casesDir.appendingPathComponent(name), encoding: .utf8)
            let expected = try String(contentsOf: expectedDir.appendingPathComponent(name), encoding: .utf8)
            let got = redactor.redact(input.trimmingTrailingNewline()).text
            XCTAssertEqual(got, expected.trimmingTrailingNewline(), "golden case \(name)")
        }
    }
}

private extension String {
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
