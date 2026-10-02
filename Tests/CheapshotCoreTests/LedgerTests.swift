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

    func testSummaryByModeSplitsAndSortsBySaved() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 1000, textTokens: 100, redactions: 2))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 500, textTokens: 100, redactions: 1))
        try ledger.append(LedgerEntry(mode: "video", inputs: 70, imageTokens: 90_000, textTokens: 8_000, redactions: 9))
        try ledger.append(LedgerEntry(mode: "pdf", inputs: 3, imageTokens: 300, textTokens: 200, redactions: 0))
        let modes = try ledger.summaryByMode()
        XCTAssertEqual(modes.map(\.mode), ["video", "image", "pdf"], "biggest saving first")
        XCTAssertEqual(modes[0].runs, 1); XCTAssertEqual(modes[0].inputs, 70)
        XCTAssertEqual(modes[0].saved, 82_000); XCTAssertEqual(modes[0].percent, 91)
        XCTAssertEqual(modes[1].runs, 2); XCTAssertEqual(modes[1].imageTokens, 1500)
        XCTAssertEqual(modes[1].saved, 1300); XCTAssertEqual(modes[1].redactions, 3)
        XCTAssertEqual(modes[2].mode, "pdf"); XCTAssertEqual(modes[2].saved, 100)
        // The split must reconcile with the whole-ledger totals, or the table lies.
        let all = try ledger.summary()
        XCTAssertEqual(modes.reduce(0) { $0 + $1.saved }, all.saved)
        XCTAssertEqual(modes.reduce(0) { $0 + $1.runs }, all.runs)
        XCTAssertEqual(modes.reduce(0) { $0 + $1.inputs }, all.inputs)
    }

    func testSummaryByModeHonoursDayWindow() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2020-01-01T00:00:00Z", mode: "pdf", inputs: 1, imageTokens: 900, textTokens: 100, redactions: 0))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 400, textTokens: 100, redactions: 0))
        XCTAssertEqual(try ledger.summaryByMode().map(\.mode), ["pdf", "image"])
        XCTAssertEqual(try ledger.summaryByMode(days: 7).map(\.mode), ["image"])
    }

    func testSummaryByModeOfMissingFileIsEmpty() throws {
        XCTAssertEqual(try Ledger(at: tmp.appendingPathComponent("nope.jsonl")).summaryByMode(), [])
    }

    func testSummaryTextByModeAlignsAndTotals() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2026-09-20T01:00:00Z", mode: "video", inputs: 70, imageTokens: 90_000, textTokens: 8_000, redactions: 9))
        try ledger.append(LedgerEntry(ts: "2026-09-20T02:00:00Z", mode: "image", inputs: 1, imageTokens: 1000, textTokens: 100, redactions: 2))
        let text = ledger.summaryTextByMode(try ledger.summary(), try ledger.summaryByMode())
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "cheapshot ledger  (1 day, by mode)")
        XCTAssertTrue(lines[1].contains("mode") && lines[1].hasSuffix("redactions"), lines[1])
        XCTAssertTrue(lines[2].contains("video"), lines[2])
        XCTAssertTrue(lines[4].contains("TOTAL") && lines[4].contains("82900"), lines[4])
        // Every row is the same width, or the columns do not line up in a terminal.
        XCTAssertEqual(Set(lines[1...4].map(\.count)).count, 1, "ragged columns: \(lines[1...4].map(\.count))")
    }

    func testSessionIsOmittedWhenUnsetSoOldLinesStayByteIdentical() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2026-09-08T01:05:35Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10))
        // An empty string is treated as absent: the hook must never record a session it did not get.
        try ledger.append(LedgerEntry(ts: "2026-09-08T01:05:36Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10, session: ""))
        let lines = try String(contentsOf: ledger.url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], #"{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}"#)
        XCTAssertFalse(lines[1].contains("session"), lines[1])
        XCTAssertNil(try ledger.entries()[0].session)
    }

    func testSessionRoundTripsAndOldLinesStillDecode() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        // A line written before the field existed must still decode, with a nil session.
        try Data((#"{"image_tokens":100,"inputs":1,"mode":"image","redactions":0,"saved":90,"text_tokens":10,"ts":"2026-09-01T00:00:00Z"}"# + "\n").utf8)
            .write(to: ledger.url)
        try ledger.append(LedgerEntry(ts: "2026-09-02T00:00:00Z", mode: "image", inputs: 1, imageTokens: 200, textTokens: 20, redactions: 0, session: "abc-123"))
        let e = try ledger.entries()
        XCTAssertEqual(e.count, 2)
        XCTAssertNil(e[0].session)
        XCTAssertEqual(e[1].session, "abc-123")
        XCTAssertTrue(try String(contentsOf: ledger.url, encoding: .utf8).contains(#""session":"abc-123""#))
    }

    func testSummaryBySessionGroupsAndKeepsUntaggedSeparate() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(mode: "video", inputs: 70, imageTokens: 90_000, textTokens: 8_000, redactions: 9, session: "sess-a"))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 1000, textTokens: 100, redactions: 2, session: "sess-a"))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 500, textTokens: 100, redactions: 0, session: "sess-b"))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 300, textTokens: 100, redactions: 0))
        let rows = try ledger.summaryBySession()
        XCTAssertEqual(rows.map(\.label), ["sess-a", "sess-b", "(untagged)"], "biggest saving first")
        XCTAssertEqual(rows[0].runs, 2); XCTAssertEqual(rows[0].saved, 82_900)
        XCTAssertNil(rows[2].session, "an untagged row keeps a nil session, it is not the literal string")
        XCTAssertEqual(rows[2].saved, 200)
        // The grouping must reconcile with the flat totals, and with the mode split.
        let all = try ledger.summary()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.saved }, all.saved)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.runs }, all.runs)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.saved }, try ledger.summaryByMode().reduce(0) { $0 + $1.saved })
    }

    func testSummaryBySessionHonoursDayWindowAndEmptyLedger() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2020-01-01T00:00:00Z", mode: "pdf", inputs: 1, imageTokens: 900, textTokens: 100, redactions: 0, session: "old"))
        try ledger.append(LedgerEntry(mode: "image", inputs: 1, imageTokens: 400, textTokens: 100, redactions: 0, session: "new"))
        XCTAssertEqual(try ledger.summaryBySession().map(\.label), ["old", "new"])
        XCTAssertEqual(try ledger.summaryBySession(days: 7).map(\.label), ["new"])
        XCTAssertEqual(try Ledger(at: tmp.appendingPathComponent("nope.jsonl")).summaryBySession(), [])
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
