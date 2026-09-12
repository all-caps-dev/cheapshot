import XCTest
@testable import CheapshotCore

final class LedgerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testResolveURLPrefersCheapshotHome() {
        let u = Ledger.resolveURL(environment: ["CHEAPSHOT_HOME": "/x/y"], home: tmp.path)
        XCTAssertEqual(u.path, "/x/y/ledger.jsonl")
    }

    func testResolveURLFallsBackToApplicationSupport() {
        let u = Ledger.resolveURL(environment: [:], home: tmp.path)
        XCTAssertEqual(u.path, tmp.path + "/Library/Application Support/cheapshot/ledger.jsonl")
    }

    func testAppendWritesOneSortedJSONLine() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("sub/ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2026-09-08T01:05:35Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10))
        let body = try String(contentsOf: ledger.url, encoding: .utf8)
        XCTAssertEqual(body, #"{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}"# + "\n")
        XCTAssertEqual(try ledger.entries().count, 1)
        XCTAssertEqual(try ledger.entries()[0].saved, 1496)
    }

    func testSavedNeverNegative() {
        let e = LedgerEntry(mode: "image", inputs: 1, imageTokens: 10, textTokens: 50, redactions: 0)
        XCTAssertEqual(e.saved, 0)
    }

    func testConcurrentAppendsDoNotInterleave() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            try? ledger.append(LedgerEntry(mode: "image", inputs: i, imageTokens: 1000 + i, textTokens: 10, redactions: 0))
        }
        let lines = try String(contentsOf: ledger.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 64)
        XCTAssertEqual(try ledger.entries().count, 64, "every line must decode")
    }

    func testSummaryTotalsAndDayFilter() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2020-01-01T00:00:00Z", mode: "image", inputs: 1, imageTokens: 1000, textTokens: 100, redactions: 2))
        try ledger.append(LedgerEntry(mode: "video", inputs: 12, imageTokens: 2000, textTokens: 500, redactions: 1))
        let all = try ledger.summary()
        XCTAssertEqual(all.runs, 2); XCTAssertEqual(all.days, 2); XCTAssertEqual(all.inputs, 13)
        XCTAssertEqual(all.imageTokens, 3000); XCTAssertEqual(all.textTokens, 600); XCTAssertEqual(all.saved, 2400)
        XCTAssertEqual(all.redactions, 3); XCTAssertEqual(all.percent, 80)
        let week = try ledger.summary(days: 7)
        XCTAssertEqual(week.runs, 1); XCTAssertEqual(week.imageTokens, 2000)
    }

    func testSummaryOfMissingFileIsZero() throws {
        let s = try Ledger(at: tmp.appendingPathComponent("nope.jsonl")).summary()
        XCTAssertEqual(s.runs, 0); XCTAssertEqual(s.percent, 0)
    }

    func testSummaryText() {
        let s = LedgerSummary(days: 1, runs: 2, inputs: 3, imageTokens: 1000, textTokens: 100, saved: 900, redactions: 4, percent: 90)
        let text = Ledger(at: tmp).summaryText(s)
        XCTAssertTrue(text.contains("cheapshot ledger  (1 day)"))
        XCTAssertTrue(text.contains("saved          900  (90%)"))
    }
}
