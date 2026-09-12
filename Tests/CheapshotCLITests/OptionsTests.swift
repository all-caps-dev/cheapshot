import XCTest
@testable import CheapshotCLI

final class OptionsTests: XCTestCase {
    func testEmptyAndHelpAndVersion() throws {
        XCTAssertEqual(try Options.parse([]).command, .help)
        XCTAssertEqual(try Options.parse(["a.png", "-h"]).command, .help)
        XCTAssertEqual(try Options.parse(["--help"]).command, .help)
        XCTAssertEqual(try Options.parse(["--version"]).command, .version)
    }

    func testFilesAndFlags() throws {
        let o = try Options.parse(["--raw", "--json", "--stats", "--no-ledger", "a.png", "b.jpg"])
        XCTAssertEqual(o.command, .files(["a.png", "b.jpg"]))
        XCTAssertFalse(o.redact); XCTAssertTrue(o.json); XCTAssertTrue(o.stats); XCTAssertTrue(o.noLedger)
    }

    func testUnknownOptionIsUsageError() {
        XCTAssertThrowsError(try Options.parse(["--bogus"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "unknown option --bogus"))
        }
        XCTAssertThrowsError(try Options.parse(["a.png", "--jsn"]))
    }

    func testNoInputsIsUsageError() {
        XCTAssertThrowsError(try Options.parse(["--json"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "no input files"))
        }
    }

    func testMinConfNeedsAValue() throws {
        XCTAssertEqual(try Options.parse(["--min-conf", "0.5", "a.png"]).minConfidence, 0.5)
        XCTAssertThrowsError(try Options.parse(["--min-conf", "shot.png"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--min-conf: not a number: shot.png"))
        }
        XCTAssertThrowsError(try Options.parse(["--min-conf"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--min-conf needs a value"))
        }
        XCTAssertThrowsError(try Options.parse(["--min-conf", "--json", "a.png"]))
    }

    func testNewestForms() throws {
        XCTAssertEqual(try Options.parse(["--newest"]).command, .newest(dir: ".", count: 1))
        XCTAssertEqual(try Options.parse(["--newest", "3"]).command, .newest(dir: ".", count: 3))
        XCTAssertEqual(try Options.parse(["--newest", "/tmp/shots"]).command, .newest(dir: "/tmp/shots", count: 1))
        XCTAssertEqual(try Options.parse(["--newest", "/tmp/shots", "2", "--json"]).command, .newest(dir: "/tmp/shots", count: 2))
    }

    func testCleanshotForms() throws {
        XCTAssertEqual(try Options.parse(["--cleanshot"]).command, .cleanshot(count: 1))
        XCTAssertEqual(try Options.parse(["--cleanshot", "3"]).command, .cleanshot(count: 3))
    }

    func testVideoOptions() throws {
        let o = try Options.parse(["--video", "v.mp4", "--scene", "0.3", "--max-frames", "10", "--dedupe", "0.8"])
        XCTAssertEqual(o.command, .video(path: "v.mp4"))
        XCTAssertEqual(o.scene, 0.3); XCTAssertEqual(o.maxFrames, 10); XCTAssertEqual(o.dedupe, 0.8)
        XCTAssertThrowsError(try Options.parse(["--video"]))
        XCTAssertThrowsError(try Options.parse(["--video", "v.mp4", "--max-frames", "ten"]))
    }

    func testTextMode() throws {
        XCTAssertEqual(try Options.parse(["--text", "-"]).command, .text(path: "-"))
        XCTAssertEqual(try Options.parse(["--text", "notes.txt", "--json"]).command, .text(path: "notes.txt"))
        XCTAssertThrowsError(try Options.parse(["--text"]))
        XCTAssertThrowsError(try Options.parse(["--text", "--json"]))
    }

    func testLedgerForms() throws {
        XCTAssertEqual(try Options.parse(["--ledger"]).command, .ledger(json: false, migrate: false))
        XCTAssertEqual(try Options.parse(["--ledger", "--json"]).command, .ledger(json: true, migrate: false))
        XCTAssertEqual(try Options.parse(["--ledger", "--migrate"]).command, .ledger(json: false, migrate: true))
        XCTAssertThrowsError(try Options.parse(["--migrate"]))
    }

    func testNumericBoundsAreValidated() {
        XCTAssertThrowsError(try Options.parse(["--newest", "-3"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--newest: count must be >= 1: -3"))
        }
        XCTAssertThrowsError(try Options.parse(["--cleanshot", "0"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--cleanshot: count must be >= 1: 0"))
        }
        XCTAssertThrowsError(try Options.parse(["--max-frames", "0", "a.png"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--max-frames: must be >= 1: 0"))
        }
        XCTAssertThrowsError(try Options.parse(["--max-frames", "-1", "a.png"]))
        XCTAssertThrowsError(try Options.parse(["--min-conf", "2.0", "a.png"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--min-conf: must be between 0 and 1: 2.0"))
        }
        XCTAssertThrowsError(try Options.parse(["--min-conf", "nan", "a.png"]))
        XCTAssertThrowsError(try Options.parse(["--min-conf", "inf", "a.png"]))
        XCTAssertThrowsError(try Options.parse(["--min-conf", "-5", "a.png"]))
        XCTAssertThrowsError(try Options.parse(["--dedupe", "-0.1", "a.png"]))
        XCTAssertThrowsError(try Options.parse(["--scene", "1.5", "a.png"]))
    }

    func testNumericBoundsAreInclusive() throws {
        XCTAssertEqual(try Options.parse(["--min-conf", "0", "a.png"]).minConfidence, 0)
        XCTAssertEqual(try Options.parse(["--min-conf", "1", "a.png"]).minConfidence, 1)
        XCTAssertEqual(try Options.parse(["--dedupe", "0", "a.png"]).dedupe, 0)
        XCTAssertEqual(try Options.parse(["--dedupe", "1", "a.png"]).dedupe, 1)
        XCTAssertEqual(try Options.parse(["--max-frames", "1", "a.png"]).maxFrames, 1)
        XCTAssertEqual(try Options.parse(["--newest", "1"]).command, .newest(dir: ".", count: 1))
        XCTAssertEqual(try Options.parse(["--cleanshot", "1"]).command, .cleanshot(count: 1))
    }

    func testSingleDashUnknownOptions() throws {
        XCTAssertThrowsError(try Options.parse(["-v"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "unknown option -v"))
        }
        XCTAssertThrowsError(try Options.parse(["-j", "a.png"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "unknown option -j"))
        }
        XCTAssertThrowsError(try Options.parse(["--newest", "-v"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "unknown option -v"))
        }
        // Bare "-" is stdin and a negative-looking token is just a filename.
        XCTAssertEqual(try Options.parse(["--text", "-"]).command, .text(path: "-"))
        XCTAssertEqual(try Options.parse(["-3.png"]).command, .files(["-3.png"]))
    }

    func testRulesAndPages() throws {
        let o = try Options.parse(["--rules", "r.json", "--pages", "1-2", "doc.pdf"])
        XCTAssertEqual(o.rulesPath, "r.json")
        XCTAssertEqual(o.pages, 1...2)
        XCTAssertEqual(try Options.parsePages("3"), 3...3)
        XCTAssertThrowsError(try Options.parsePages("2-1"))
        XCTAssertThrowsError(try Options.parsePages("0-1"))
        XCTAssertThrowsError(try Options.parsePages("x"))
    }
}
