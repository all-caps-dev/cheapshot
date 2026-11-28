// Swift. Redact.publish (CHE-73, redact engine plan P4): the no-clobber step that gives verified
// bytes their final name. Every test works in its own fresh temp folder and checks the folder
// listing afterwards, so a leftover temp file or a replaced file shows up as a failure.
// No AppKit and no Process: these tests also run on the iOS Simulator (scripts/check-ios-core.sh).
import XCTest
import CryptoKit
@testable import CheapshotCore

final class PublishTests: XCTestCase {
    private var dir: URL!
    private var savedOps: Redact.PublishOps!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        savedOps = Redact.publishOps
    }

    override func tearDownWithError() throws {
        // Put the live file calls back even when a test injected failing ones.
        Redact.publishOps = savedOps
        try? fm.removeItem(at: dir)
    }

    // MARK: helpers

    /// Lowercase hex SHA-256 of a file's bytes, or "" when it cannot be read.
    private func sha(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted names in a folder, hidden ones included (temp files start with a dot).
    private func listing(_ folder: URL? = nil) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: (folder ?? dir).path)) ?? []).sorted()
    }

    /// Permission bits of a path, not following a symlink.
    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return st.st_mode & 0o777
    }

    private func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)   // test fixture only; the code under test never does this
        return url
    }

    /// Runs publish and returns its PublishError, failing the test when it succeeds or throws
    /// something else.
    private func publishError(_ data: Data, to final: URL, inputs: [URL] = [],
                              verify: (URL) throws -> Void = { _ in },
                              file: StaticString = #filePath, line: UInt = #line) -> Redact.PublishError? {
        do {
            _ = try Redact.publish(data, to: final, inputs: inputs, verify: verify)
            XCTFail("publish succeeded, expected an error", file: file, line: line)
        } catch let e as Redact.PublishError {
            return e
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    /// Runs `body` with the process umask set to `mask`, then restores it.
    private func withUmask<T>(_ mask: mode_t, _ body: () throws -> T) rethrows -> T {
        let old = umask(mask)
        defer { umask(old) }
        return try body()
    }

    private let payload = Data("redacted bytes \(UUID().uuidString)".utf8)

    /// A file call that fails with `code`, standing in for a volume that refuses it.
    private static func failing(_ code: Int32) -> (Int32, String, String) -> Int32 {
        { _, _, _ in errno = code; return -1 }
    }

    // MARK: tests

    /// M9: a name that already exists is a clash and keeps its bytes, whether it was there
    /// before publish started or appeared while verify ran (so the link itself must refuse).
    func testExistingFinalKeepsItsBytesAndIsAClash() throws {
        let final = try write("original bytes", "out.png")
        let before = sha(final)
        XCTAssertEqual(publishError(payload, to: final), .clash(final))
        XCTAssertEqual(sha(final), before)
        XCTAssertEqual(listing(), ["out.png"])

        // Appears after the early existence check, during verify: only the no-clobber link stops it.
        let late = dir.appendingPathComponent("late.png")
        XCTAssertEqual(publishError(payload, to: late, verify: { _ in
            try Data("someone else".utf8).write(to: late)
        }), .clash(late))
        XCTAssertEqual(try Data(contentsOf: late), Data("someone else".utf8))
        XCTAssertEqual(listing(), ["late.png", "out.png"])
    }

    /// Rule 25: a symlink at the final name is a clash; its target is not written or created.
    func testSymlinkAtFinalIsNotFollowed() throws {
        let target = try write("target bytes", "target.png")
        let before = sha(target)
        let link = dir.appendingPathComponent("out.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(publishError(payload, to: link), .clash(link))
        XCTAssertEqual(sha(target), before)
        XCTAssertTrue(isSymlink(link))

        // A dangling symlink: following it would create the file it points at.
        let ghost = dir.appendingPathComponent("ghost.png")
        let dangling = dir.appendingPathComponent("dangling.png")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: ghost)
        XCTAssertEqual(publishError(payload, to: dangling), .clash(dangling))
        XCTAssertFalse(fm.fileExists(atPath: ghost.path))

        // Same, when the symlink appears during verify, so the link call meets it.
        let late = dir.appendingPathComponent("late.png")
        let lateGhost = dir.appendingPathComponent("late-ghost.png")
        XCTAssertEqual(publishError(payload, to: late, verify: { _ in
            try self.fm.createSymbolicLink(at: late, withDestinationURL: lateGhost)
        }), .clash(late))
        XCTAssertFalse(fm.fileExists(atPath: lateGhost.path))
        XCTAssertEqual(listing(), ["dangling.png", "late.png", "out.png", "target.png"])
    }

    /// M10: an output that resolves to an input is refused: the same path, the same file reached
    /// through a symlinked folder, a hard link to the input, and a case variant of its name.
    func testFinalThatResolvesToAnInputIsRefused() throws {
        let input = try write("the original", "shot.png")
        let before = sha(input)
        let alias = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: dir)
        let hard = dir.appendingPathComponent("hard.png")
        XCTAssertEqual(link(input.path, hard.path), 0)
        let listed = listing()

        let samePath = input
        XCTAssertEqual(publishError(payload, to: samePath, inputs: [input]), .isInput(samePath))
        let viaAlias = alias.appendingPathComponent("shot.png")
        XCTAssertEqual(publishError(payload, to: viaAlias, inputs: [input]), .isInput(viaAlias))
        // The other way round: the input was named through the symlinked folder.
        XCTAssertEqual(publishError(payload, to: samePath, inputs: [viaAlias]), .isInput(samePath))
        XCTAssertEqual(publishError(payload, to: hard, inputs: [input]), .isInput(hard))
        // Case variant: refused by name on every volume, so APFS's one-name-for-both never matters.
        let caseVariant = dir.appendingPathComponent("SHOT.png")
        XCTAssertEqual(publishError(payload, to: caseVariant, inputs: [input]), .isInput(caseVariant))
        // NFD spelling of an NFC input name is the same name too.
        let accented = try write("accented original", "caf\u{00E9}.png")
        let nfd = dir.appendingPathComponent("cafe\u{0301}.png")
        XCTAssertEqual(publishError(payload, to: nfd, inputs: [accented]), .isInput(nfd))
        try fm.removeItem(at: accented)
        // An input that is no longer on disk still owns its name: only the path comparison can
        // see these (no inode to match), so they pin its case folding and NFC on their own.
        let gone = dir.appendingPathComponent("gone.png")
        XCTAssertEqual(publishError(payload, to: gone, inputs: [gone]), .isInput(gone))
        let goneCase = dir.appendingPathComponent("gone-case.png")
        XCTAssertEqual(publishError(payload, to: goneCase, inputs: [dir.appendingPathComponent("Gone-Case.png")]),
                       .isInput(goneCase))
        let goneNFD = dir.appendingPathComponent("gone-cafe\u{0301}.png")
        XCTAssertEqual(publishError(payload, to: goneNFD, inputs: [dir.appendingPathComponent("gone-caf\u{00E9}.png")]),
                       .isInput(goneNFD))

        XCTAssertEqual(sha(input), before)
        XCTAssertEqual(listing(), listed)
    }

    /// M13: every failure leaves the folder exactly as it was (plus what the case itself put there).
    func testEveryFailurePathLeavesNoTemp() throws {
        struct VerifyRefused: Error {}
        struct Case {
            let name: String
            let ops: (inout Redact.PublishOps) -> Void
            let verify: (URL) throws -> Void
            let expect: (URL) -> Redact.PublishError
            let extra: [String]          // names the case itself creates
        }
        let existing = "existing.png"
        var shortWrites = 0
        let cases: [Case] = [
            Case(name: "clash before", ops: { _ in }, verify: { _ in },
                 expect: { _ in .clash(self.dir.appendingPathComponent(existing)) }, extra: []),
            Case(name: "clash at link", ops: { _ in }, verify: { u in
                    try Data("x".utf8).write(to: u.deletingLastPathComponent().appendingPathComponent("out-clash at link.png"))
                 }, expect: { .clash($0) }, extra: ["out-clash at link.png"]),
            Case(name: "verify throws", ops: { _ in }, verify: { _ in throw VerifyRefused() },
                 expect: { _ in .verifyFailed(String(describing: VerifyRefused())) }, extra: []),
            Case(name: "link fails", ops: { $0.link = PublishTests.failing(EIO) }, verify: { _ in },
                 expect: { _ in .write("link: \(String(cString: strerror(EIO)))") }, extra: []),
            Case(name: "rename fails", ops: {
                    $0.link = PublishTests.failing(ENOTSUP); $0.renameExcl = PublishTests.failing(EIO)
                 }, verify: { _ in },
                 expect: { _ in .write("rename: \(String(cString: strerror(EIO)))") }, extra: []),
            Case(name: "exclusive create clashes", ops: {
                    $0.link = PublishTests.failing(ENOTSUP); $0.renameExcl = PublishTests.failing(ENOTSUP)
                 }, verify: { u in
                    try Data("x".utf8).write(to: u.deletingLastPathComponent().appendingPathComponent("out-exclusive create clashes.png"))
                 }, expect: { .clash($0) }, extra: ["out-exclusive create clashes.png"]),
            Case(name: "short write", ops: { $0.write = { _, _, _ in 0 } }, verify: { _ in },
                 expect: { _ in .write("short write") }, extra: []),
            // The temp file writes fine; the copy made at the final name by the last fallback does not.
            Case(name: "short write at final", ops: {
                    $0.link = PublishTests.failing(ENOTSUP); $0.renameExcl = PublishTests.failing(ENOTSUP)
                    let live = Redact.PublishOps.live.write
                    $0.write = { fd, p, n in
                        shortWrites += 1
                        return shortWrites == 1 ? live(fd, p, n) : 0
                    }
                 }, verify: { _ in }, expect: { _ in .write("short write") }, extra: []),
        ]
        _ = try write("keep me", existing)
        let base = listing()

        // Rule 26: a temp name that is already taken, by a file or by a symlink, is refused
        // (O_EXCL, O_NOFOLLOW); the planted file keeps its bytes and the symlink's target is not made.
        let plantedFile = try write("planted", ".cheapshot-planted.tmp")
        let plantedLink = dir.appendingPathComponent(".cheapshot-link.tmp")
        let linkTarget = dir.appendingPathComponent("link-target.png")
        try fm.createSymbolicLink(at: plantedLink, withDestinationURL: linkTarget)
        for planted in [plantedFile, plantedLink] {
            var ops = Redact.PublishOps.live
            ops.tempName = { planted.lastPathComponent }
            Redact.publishOps = ops
            let final = dir.appendingPathComponent("out-planted.png")
            guard case .write? = publishError(payload, to: final) else {
                XCTFail("planted \(planted.lastPathComponent): expected a write error"); continue
            }
            XCTAssertEqual(listing(), (base + [".cheapshot-link.tmp", ".cheapshot-planted.tmp"]).sorted())
            Redact.publishOps = .live
        }
        XCTAssertEqual(try Data(contentsOf: plantedFile), Data("planted".utf8))
        XCTAssertFalse(fm.fileExists(atPath: linkTarget.path))
        try fm.removeItem(at: plantedFile)
        try fm.removeItem(at: plantedLink)

        for c in cases {
            shortWrites = 0
            var ops = Redact.PublishOps.live
            c.ops(&ops)
            Redact.publishOps = ops
            let final = c.name == "clash before" ? dir.appendingPathComponent(existing)
                                                 : dir.appendingPathComponent("out-\(c.name).png")
            let err = publishError(payload, to: final, verify: c.verify)
            XCTAssertEqual(err, c.expect(final), c.name)
            XCTAssertEqual(listing(), (base + c.extra).sorted(), "\(c.name): folder changed")
            Redact.publishOps = .live
            for e in c.extra { try? fm.removeItem(at: dir.appendingPathComponent(e)) }
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(existing)), Data("keep me".utf8))
    }

    /// CHE-73: where hard links are refused, publish falls back to renameatx_np(RENAME_EXCL), then
    /// to an O_EXCL | O_NOFOLLOW create at the final name. Each step still refuses an existing name.
    func testLinkFailureFallsBackToRenameExclThenExclCreate() throws {
        var calls: [String] = []
        let live = Redact.PublishOps.live

        // Step 2: link refused, rename-exclusive used.
        var ops = live
        ops.link = { fd, a, b in calls.append("link"); errno = ENOTSUP; return -1 }
        ops.renameExcl = { fd, a, b in calls.append("rename"); return live.renameExcl(fd, a, b) }
        Redact.publishOps = ops
        let viaRename = dir.appendingPathComponent("rename.png")
        let p1 = try withUmask(0o022) { try Redact.publish(payload, to: viaRename, inputs: []) }
        XCTAssertEqual(calls, ["link", "rename"])
        XCTAssertEqual(try Data(contentsOf: viaRename), payload)
        XCTAssertEqual(p1.url, viaRename)
        XCTAssertEqual(mode(viaRename), 0o644)
        XCTAssertEqual(listing(), ["rename.png"])
        // An existing name, met by rename-exclusive (it appears during verify).
        calls = []
        let renameClash = dir.appendingPathComponent("rename-clash.png")
        XCTAssertEqual(publishError(payload, to: renameClash, verify: { _ in
            try Data("theirs".utf8).write(to: renameClash)
        }), .clash(renameClash))
        XCTAssertEqual(calls, ["link", "rename"])
        XCTAssertEqual(try Data(contentsOf: renameClash), Data("theirs".utf8))

        // Step 3: link and rename both refused, exclusive create used.
        calls = []
        ops.renameExcl = { _, _, _ in calls.append("rename"); errno = ENOTSUP; return -1 }
        Redact.publishOps = ops
        let viaCreate = dir.appendingPathComponent("create.png")
        let p2 = try withUmask(0o022) { try Redact.publish(payload, to: viaCreate, inputs: []) }
        XCTAssertEqual(calls, ["link", "rename"])
        XCTAssertEqual(try Data(contentsOf: viaCreate), payload)
        XCTAssertEqual(p2.sha256, sha(viaCreate))
        XCTAssertEqual(mode(viaCreate), 0o644)
        // An existing file and a dangling symlink, both met by the exclusive create.
        let createClash = dir.appendingPathComponent("create-clash.png")
        XCTAssertEqual(publishError(payload, to: createClash, verify: { _ in
            try Data("theirs".utf8).write(to: createClash)
        }), .clash(createClash))
        XCTAssertEqual(try Data(contentsOf: createClash), Data("theirs".utf8))
        let ghost = dir.appendingPathComponent("ghost.png")
        let dangling = dir.appendingPathComponent("dangling.png")
        XCTAssertEqual(publishError(payload, to: dangling, verify: { _ in
            try self.fm.createSymbolicLink(at: dangling, withDestinationURL: ghost)
        }), .clash(dangling))
        XCTAssertFalse(fm.fileExists(atPath: ghost.path))
        XCTAssertEqual(listing(), ["create-clash.png", "create.png", "dangling.png", "rename-clash.png", "rename.png"])
    }

    /// Parity plan 5.5: the temp file is 0600 while verify looks at it, sits in the destination
    /// folder, and the published file then gets the umask's default mode (it is meant to be shared).
    func testTempIsCreated0600AndFinalFollowsTheUmask() throws {
        let final = dir.appendingPathComponent("out.png")
        var seen: (mode: mode_t, folder: String, name: String, bytes: Data?)?
        let realDir = URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path
        _ = try withUmask(0o027) {
            try Redact.publish(payload, to: final, inputs: []) { temp in
                seen = (self.mode(temp), temp.deletingLastPathComponent().resolvingSymlinksInPath().path,
                        temp.lastPathComponent, try? Data(contentsOf: temp))
            }
        }
        XCTAssertEqual(seen?.mode, 0o600)
        XCTAssertEqual(seen?.folder, realDir)
        XCTAssertTrue(seen?.name.hasPrefix(".cheapshot-") == true && seen?.name.hasSuffix(".tmp") == true)
        XCTAssertEqual(seen?.bytes, payload)        // verify sees the complete bytes
        XCTAssertEqual(mode(final), 0o640)
        XCTAssertEqual(listing(), ["out.png"])
    }

    /// Parity plan 5.5: what lands on disk is exactly the input, and the reported hash and size match.
    func testPublishedBytesAndHashMatch() throws {
        let final = dir.appendingPathComponent("out.png")
        let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })   // several write chunks
        let p = try Redact.publish(big, to: final, inputs: [])
        XCTAssertEqual(try Data(contentsOf: final), big)
        XCTAssertEqual(p.url, final)
        XCTAssertEqual(p.bytes, big.count)
        XCTAssertEqual(p.sha256, SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(p.sha256, sha(final))
        XCTAssertEqual(listing(), ["out.png"])
    }

    /// A destination reached through a symlinked folder works (that is how ~/Dropbox is set up).
    func testSymlinkedDestinationFolderWorks() throws {
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let final = alias.appendingPathComponent("out.png")
        let p = try Redact.publish(payload, to: final, inputs: [])
        XCTAssertEqual(p.url, final)
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("out.png")), payload)
        XCTAssertEqual(listing(real), ["out.png"])
        XCTAssertTrue(isSymlink(alias))
    }

    /// Rule 25: eight threads racing for one name give exactly one winner, whose bytes are whole.
    func testConcurrentPublishesToOneNameGiveOneWinner() throws {
        let final = dir.appendingPathComponent("out.png")
        let blobs = (0..<8).map { i in Data(repeating: UInt8(i + 1), count: 256 * 1024) }
        let lock = NSLock()
        var wins: [Int] = []
        var clashes = 0
        var others: [String] = []
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            do {
                _ = try Redact.publish(blobs[i], to: final, inputs: [])
                lock.lock(); wins.append(i); lock.unlock()
            } catch Redact.PublishError.clash {
                lock.lock(); clashes += 1; lock.unlock()
            } catch {
                lock.lock(); others.append("\(error)"); lock.unlock()
            }
        }
        XCTAssertEqual(others, [])
        XCTAssertEqual(wins.count, 1)
        XCTAssertEqual(clashes, 7)
        if let w = wins.first { XCTAssertEqual(try Data(contentsOf: final), blobs[w]) }
        XCTAssertEqual(listing(), ["out.png"])
    }

    /// Scope: publish never makes folders. A missing one is an error and stays missing.
    func testMissingFolderIsAnErrorNotACreate() throws {
        let missing = dir.appendingPathComponent("missing", isDirectory: true)
        let final = missing.appendingPathComponent("out.png")
        guard case .unsafeDestination? = publishError(payload, to: final) else {
            return XCTFail("expected unsafeDestination")
        }
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
        XCTAssertEqual(listing(), [])
    }

    /// Rules 22 and 23 at the last step: a name that is empty, a dot name, or holds a control
    /// character, and a URL that names a folder, are refused before anything is created.
    func testUnsafeNamesAreRefused() throws {
        let finals = [
            URL(fileURLWithPath: dir.path + "/out\u{7}.png"),
            URL(fileURLWithPath: dir.path + "/line\nbreak.png"),
            URL(fileURLWithPath: dir.path + "/out.png/", isDirectory: true),
            URL(string: "https://example.invalid/out.png")!,
        ]
        for f in finals {
            guard case .unsafeDestination? = publishError(payload, to: f) else {
                XCTFail("expected unsafeDestination for \(f)"); continue
            }
        }
        for name in [".", ".."] {
            XCTAssertThrowsError(try Redact.checkName(name), name)
        }
        XCTAssertNoThrow(try Redact.checkName("out.png"))
        XCTAssertEqual(listing(), [])
    }

    /// Rule 28: no file in Sources/CheapshotCore/Redact/ calls something that can replace an
    /// existing name. A race-free test cannot catch moveItem's check-then-rename, so this reads
    /// the source. Comments are dropped first, so the rule can be written down in them.
    func testRedactSourcesUseNoReplacingFileCalls() throws {
        let redactDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheapshotCore/Redact", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: redactDir.path) else {
            // The iOS Simulator may not see the source tree; the macOS run always does.
            throw XCTSkip("source folder not readable here: \(redactDir.path)")
        }
        let swiftFiles = names.filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(swiftFiles.contains("Publish.swift"))
        let banned = [
            #"\.write\(to:"#,                       // Data.write(to:options:), String.write(to:)
            #"replaceItem"#, #"moveItem"#, #"copyItem"#,
            #"(?<![A-Za-z0-9_])rename\("#,          // rename(2), Darwin.rename(...)
            #"(?<![A-Za-z0-9_])renameat\("#,        // renameat(2) without RENAME_EXCL
        ].map { try! NSRegularExpression(pattern: $0) }
        for file in swiftFiles {
            let text = try String(contentsOf: redactDir.appendingPathComponent(file), encoding: .utf8)
            for (n, raw) in text.components(separatedBy: "\n").enumerated() {
                let code = raw.components(separatedBy: "//").first ?? ""
                let range = NSRange(code.startIndex..., in: code)
                for re in banned where re.firstMatch(in: code, range: range) != nil {
                    XCTFail("\(file):\(n + 1) uses a banned call (\(re.pattern)): \(raw.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}
