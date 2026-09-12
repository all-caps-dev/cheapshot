import XCTest
@testable import CheapshotCLI
import CheapshotCore

/// Captures everything the runner writes so tests never touch the real stdout or the real home.
struct Capture {
    var out = "", err = ""
    var stdin = ""
    var environment: [String: String] = [:]
    var home: String

    init(home: String) { self.home = home }
}

final class RunnerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], stdin: String = "", env: [String: String] = [:]) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        var env = env
        env["CHEAPSHOT_HOME"] = env["CHEAPSHOT_HOME"] ?? tmp.path   // never write the real ledger
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { stdin },
                       environment: env, home: tmp.path)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testMissingFileIsAnErrorEntryAndExit1() async throws {
        let r = await run(["--json", "missing.png"])
        XCTAssertEqual(r.code, 1)
        let payload = try json(r.out)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["file"] as? String, "missing.png")
        XCTAssertNotNil(results[0]["error"] as? String)
        XCTAssertEqual(payload["version"] as? String, cheapshotVersionForTests)
    }

    func testMissingFileWithoutJSONStillExit1() async {
        let r = await run(["missing.png"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("missing.png"))
    }

    func testUnknownFlagExit2() async {
        let r = await run(["--bogus"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("unknown option --bogus"))
    }

    func testMinConfWithoutValueExit2() async {
        let r = await run(["--min-conf", "shot.png"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("--min-conf"))
    }

    func testTextStdinRedactsWithContextCueOnly() async {
        let r = await run(["--text", "-"], stdin: "acct 12345678\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "acct [BANK_ACCT]\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path), "--text must not write the ledger")
    }

    func testTextFileAndJSON() async throws {
        let f = tmp.appendingPathComponent("in.txt")
        try "key AKIAIOSFODNN7EXAMPLE".write(to: f, atomically: true, encoding: .utf8)
        let r = await run(["--text", f.path, "--json"])
        XCTAssertEqual(r.code, 0)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["text"] as? String, "key [AWS_KEY]")
        XCTAssertEqual((results[0]["redactions"] as? [String: Int])?["AWS_KEY"], 1)
        XCTAssertEqual(results[0]["image_tokens"] as? Int, 0)
    }

    func testTextRawSkipsRedaction() async {
        let r = await run(["--text", "-", "--raw"], stdin: "ryan@example.com")
        XCTAssertEqual(r.out, "ryan@example.com\n")
    }

    func testRulesFileApplies() async throws {
        let rules = tmp.appendingPathComponent("rules.json")
        try #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"}]"#.write(to: rules, atomically: true, encoding: .utf8)
        let r = await run(["--rules", rules.path, "--text", "-"], stdin: "INT-123456 ryan@example.com")
        XCTAssertEqual(r.out, "[TICKET] [EMAIL]\n")
    }

    func testBadRulesFileExit2() async {
        let r = await run(["--rules", "/nonexistent.json", "--text", "-"], stdin: "x")
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("rules"))
    }

    func testHelpAndVersion() async {
        let h = await run([])
        XCTAssertEqual(h.code, 0)
        XCTAssertTrue(h.out.contains("USAGE"))
        let v = await run(["--version"])
        XCTAssertEqual(v.out, cheapshotVersionForTests + "\n")
    }
}

let cheapshotVersionForTests = cheapshotVersion
