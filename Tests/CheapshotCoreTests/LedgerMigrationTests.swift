import XCTest
@testable import CheapshotCore

final class LedgerMigrationTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledger-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("tsv"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testMigratesTSVOnceAndLeavesSourceInPlace() throws {
        let tsv = tmp.appendingPathComponent("tsv")
        try "2026-09-08T01:05:35Z\timage\t1\t1550\t54\t1496\t10\n2026-09-08T02:00:00Z\tvideo\t12\t2000\t500\t1500\t0\n"
            .write(to: tsv.appendingPathComponent("20260908.tsv"), atomically: true, encoding: .utf8)
        try "2026-09-09T01:00:00Z\timage\t2\t100\t10\t90\t1\nshort\tline\n"
            .write(to: tsv.appendingPathComponent("20260909.tsv"), atomically: true, encoding: .utf8)

        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 3)
        let entries = try ledger.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], LedgerEntry(ts: "2026-09-08T01:05:35Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10))
        XCTAssertEqual(entries[1].mode, "video")
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 0, "second migrate is a no-op")
        XCTAssertEqual(try ledger.entries().count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tsv.appendingPathComponent("20260908.tsv").path), "TSV left in place")
    }

    /// Writing the marker after a zero import locked out every later `--migrate`: the TSV files
    /// may simply not be there yet when the first summary is asked for.
    func testZeroImportLeavesNoMarkerSoALaterRunStillImports() throws {
        let tsv = tmp.appendingPathComponent("tsv")          // exists, no .tsv files in it
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.migrationMarker.path),
                       "a zero import must leave no marker")
        try "2026-09-08T01:05:35Z\timage\t1\t1550\t54\t1496\t10\n"
            .write(to: tsv.appendingPathComponent("20260908.tsv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 1, "a later run with TSV data present imports")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.migrationMarker.path))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 0, "and then it is a no-op again")
    }

    func testMigrateWithNoTSVDirectoryIsZero() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tmp.appendingPathComponent("missing")), 0)
    }

    func testDefaultTSVDirectory() {
        XCTAssertEqual(Ledger.defaultTSVDirectory(home: "/h").path, "/h/.claude/cheapshot-ledger")
    }
}
