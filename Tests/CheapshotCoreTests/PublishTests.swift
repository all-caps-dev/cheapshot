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

    /// Runs `body` with the process umask set to `mask`, then restores it. Publish reads the
    /// umask once per process and keeps it, so the kept value is dropped on both sides.
    private func withUmask<T>(_ mask: mode_t, _ body: () throws -> T) rethrows -> T {
        let old = umask(mask)
        Redact.forgetUmask()
        defer { umask(old); Redact.forgetUmask() }
        return try body()
    }

    /// True when something (a file, a folder, a symlink, even a dangling one) has this path.
    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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
            // A write error keeps its errno: a full disk must not read as "short write".
            Case(name: "write error", ops: { $0.write = { _, _, _ in errno = ENOSPC; return -1 } }, verify: { _ in },
                 expect: { _ in .write("write: \(String(cString: strerror(ENOSPC)))") }, extra: []),
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
        let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })   // not one repeated byte
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

    /// Review fix 1: the temp file (or, on the last fallback, the new final file) is swapped for
    /// a different file or for a symlink to the unredacted input after verify looked at it. The
    /// swap must never end up under the final name: publish throws, no temp is left, the final
    /// name is absent, and the input keeps its bytes.
    func testSwapAfterVerifyNeverPublishesTheSwappedFile() throws {
        let input = try write("the unredacted original", "shot.png")
        let before = sha(input)
        let base = listing()
        let live = Redact.PublishOps.live
        // symlinkToOurFile moves our own file aside and points a symlink at it: same inode when
        // followed, so only a check that does not follow symlinks refuses it.
        enum Kind: CaseIterable { case otherFile, symlinkToInput, symlinkToOurFile }
        enum Point: CaseIterable { case afterVerify, insideLink, insideRename, duringFinalCreate }

        /// Puts something else at `url`: a different regular file, a symlink to the input, or a
        /// symlink to our own file moved to `<name>.aside`.
        func swap(_ url: URL, _ kind: Kind) {
            switch kind {
            case .otherFile:
                unlink(url.path)
                try? Data("bytes nobody checked".utf8).write(to: url)
            case .symlinkToInput:
                unlink(url.path)
                _ = symlink(input.path, url.path)
            case .symlinkToOurFile:
                let aside = url.path + ".aside"
                _ = Darwin.rename(url.path, aside)   // test fixture; Sources may not call rename
                _ = symlink(aside, url.path)
            }
        }

        for point in Point.allCases {
            for kind in Kind.allCases {
                let label = "\(point) \(kind)"
                let final = dir.appendingPathComponent("out-\(point)-\(kind).png")
                var linkCalls = 0
                var verify: (URL) throws -> Void = { _ in }
                var ops = live
                switch point {
                case .afterVerify:
                    // The swap happens as verify returns, before publish looks at the temp again.
                    verify = { swap($0, kind) }
                    ops.link = { fd, a, b in linkCalls += 1; return live.link(fd, a, b) }
                case .insideLink:
                    // After every check publish makes before the link: only the check after it can see this.
                    ops.link = { fd, a, b in swap(self.dir.appendingPathComponent(a), kind); return live.link(fd, a, b) }
                case .insideRename:
                    ops.link = PublishTests.failing(ENOTSUP)
                    ops.renameExcl = { fd, a, b in
                        swap(self.dir.appendingPathComponent(a), kind); return live.renameExcl(fd, a, b)
                    }
                case .duringFinalCreate:
                    ops.link = PublishTests.failing(ENOTSUP)
                    ops.renameExcl = PublishTests.failing(ENOTSUP)
                    var writes = 0
                    ops.write = { fd, p, n in
                        writes += 1
                        let r = live.write(fd, p, n)
                        if writes == 2 { swap(final, kind) }   // write 1 is the temp, write 2 the final file
                        return r
                    }
                }
                Redact.publishOps = ops
                guard case .write? = publishError(payload, to: final, inputs: [input], verify: verify) else {
                    XCTFail("\(label): expected a write error"); Redact.publishOps = live; continue
                }
                Redact.publishOps = live
                for n in listing() where n.hasSuffix(".aside") { unlink(dir.appendingPathComponent(n).path) }
                XCTAssertFalse(exists(final), "\(label): something was left under the final name")
                XCTAssertEqual(listing(), base, "\(label): folder changed")
                if point == .afterVerify { XCTAssertEqual(linkCalls, 0, "\(label): a swapped temp was linked") }
            }
        }
        XCTAssertEqual(sha(input), before)
    }

    /// Review fix 2: publish never changes the process umask, even with many publishes at once,
    /// and every file gets 0666 minus that umask. (Setting and restoring the umask per call left
    /// it at 0 now and then, so files came out 0666.)
    func testConcurrentPublishesKeepTheUmaskAndTheMode() throws {
        withUmask(0o022) {
            let rounds = 750
            for round in 0..<rounds {
                DispatchQueue.concurrentPerform(iterations: 4) { i in
                    _ = try? Redact.publish(payload, to: dir.appendingPathComponent("r\(round)-\(i).png"), inputs: [])
                }
            }
            let now = umask(0o022)
            XCTAssertEqual(now, 0o022, "the process umask changed")
            let names = listing()
            XCTAssertEqual(names.count, rounds * 4)
            let wrong = names.filter { mode(dir.appendingPathComponent($0)) != 0o644 }
            XCTAssertEqual(wrong.count, 0, "files without mode 0644, first few: \(wrong.prefix(5))")
        }
    }

    /// Review fix 3: writes that return part of the buffer, and one interrupted by a signal
    /// (EINTR), are carried on; the file on disk still holds exactly the input.
    func testPartialAndInterruptedWritesStillWriteEveryByte() throws {
        let live = Redact.PublishOps.live.write
        var calls = 0
        var ops = Redact.PublishOps.live
        ops.write = { fd, p, n in
            calls += 1
            if calls == 2 { errno = EINTR; return -1 }
            return live(fd, p, min(n, 997))   // never more than 997 bytes at a time
        }
        Redact.publishOps = ops
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let final = dir.appendingPathComponent("out.png")
        let p = try Redact.publish(data, to: final, inputs: [])
        XCTAssertEqual(try Data(contentsOf: final), data)
        XCTAssertEqual(p.sha256, sha(final))
        XCTAssertGreaterThan(calls, 11)
        XCTAssertEqual(listing(), ["out.png"])
    }

    /// Review fix 5: ".." is applied after symlinks are resolved, as the kernel does, so
    /// link/../shot.png is the folder above the link's target, not the folder holding the link.
    func testDotDotIsResolvedAfterSymlinks() throws {
        let real = dir.appendingPathComponent("real", isDirectory: true)
        let sub = real.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: sub)
        _ = try write("the original", "real/shot.png")
        let viaDotDot = URL(fileURLWithPath: dir.path + "/link/../shot.png")
        XCTAssertTrue(viaDotDot.path.contains("/link/../"), "the URL kept its .. (test premise)")

        // Not an input: dir/shot.png is a different file from real/shot.png.
        let other = dir.appendingPathComponent("shot.png")
        XCTAssertNoThrow(try Redact.publish(payload, to: other, inputs: [viaDotDot]))
        // A missing input named through link/.. still owns real/gone.png.
        let gone = real.appendingPathComponent("gone.png")
        XCTAssertEqual(publishError(payload, to: gone, inputs: [URL(fileURLWithPath: dir.path + "/link/../gone.png")]),
                       .isInput(gone))
        XCTAssertFalse(exists(gone))
    }

    // MARK: rule 28, banned calls

    /// Calls that can replace an existing name or write through a path. Matched on code with
    /// comments and string literals blanked out, so a pattern may span line breaks.
    private static let bannedCalls: [NSRegularExpression] = [
        #"\.write\(\s*to(File)?\s*:"#,                 // Data/String .write(to:) and .write(toFile:)
        #"replaceItem"#, #"moveItem"#, #"copyItem"#,
        #"createFile\(\s*atPath\s*:"#,
        #"FileHandle\(\s*forWriting"#,                 // forWritingTo:, forWritingAtPath:
        #"CGImageDestinationCreateWithURL"#,
        #"copyfile\("#,                                // copyfile and fcopyfile
        #"(?<![A-Za-z0-9_])renamex_np\("#,
        #"RENAME_SWAP"#, #"O_TRUNC"#,
        #"(?<![A-Za-z0-9_])rename\("#,                 // rename(2), Darwin.rename(...)
        #"(?<![A-Za-z0-9_])renameat\("#,               // renameat(2) without RENAME_EXCL
    ].map { try! NSRegularExpression(pattern: $0) }

    /// `text` with every comment and the inside of every string literal replaced by spaces
    /// (newlines kept, so offsets still give line numbers). String interpolation `\( ... )` is
    /// code again, so a call hidden inside one is still seen.
    static func codeOnly(_ text: String) -> String {
        let c = Array(text)
        var out = c
        // Each entry is what we are inside: a string (with its closing delimiter) or an
        // interpolation (with how many parentheses are open in it).
        enum Frame { case string(close: [Character], raw: Bool), interp(depth: Int) }
        var stack: [Frame] = []
        var i = 0
        func blank(_ from: Int, _ to: Int) { for k in from..<min(to, c.count) where c[k] != "\n" { out[k] = " " } }
        func starts(_ s: String, at k: Int) -> Bool {
            let a = Array(s)
            return k + a.count <= c.count && Array(c[k..<k + a.count]) == a
        }
        while i < c.count {
            if case .string(let close, let raw)? = stack.last {
                if !raw, c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" {
                    blank(i, i + 2); stack.append(.interp(depth: 1)); i += 2; continue
                }
                if !raw, c[i] == "\\" { blank(i, i + 2); i += 2; continue }
                if starts(String(close), at: i) { stack.removeLast(); i += close.count; continue }
                blank(i, i + 1); i += 1; continue
            }
            // Code (top level or inside an interpolation).
            if starts("//", at: i) {
                var j = i; while j < c.count, c[j] != "\n" { j += 1 }
                blank(i, j); i = j; continue
            }
            if starts("/*", at: i) {
                var j = i + 2; while j < c.count, !starts("*/", at: j) { j += 1 }
                blank(i, j + 2); i = j + 2; continue
            }
            if c[i] == "#" || c[i] == "\"" {
                var hashes = 0; var j = i
                while j < c.count, c[j] == "#" { hashes += 1; j += 1 }
                if j < c.count, c[j] == "\"" {
                    let triple = starts("\"\"\"", at: j)
                    let quote = triple ? "\"\"\"" : "\""
                    let close = Array(quote + String(repeating: "#", count: hashes))
                    stack.append(.string(close: close, raw: hashes > 0))
                    i = j + quote.count; continue
                }
            }
            if case .interp(let depth)? = stack.last {
                if c[i] == "(" { stack[stack.count - 1] = .interp(depth: depth + 1) }
                if c[i] == ")" {
                    if depth == 1 { stack.removeLast(); out[i] = " "; i += 1; continue }
                    stack[stack.count - 1] = .interp(depth: depth - 1)
                }
            }
            i += 1
        }
        return String(out)
    }

    /// Every banned call in `text`, as "line N: pattern". Also flags a renameatx_np call whose
    /// arguments do not include RENAME_EXCL (flags 0 replaces like rename).
    static func bannedCallsIn(_ text: String) -> [String] {
        let code = codeOnly(text)
        let ns = code as NSString
        func line(_ offset: Int) -> Int { ns.substring(to: offset).filter { $0 == "\n" }.count + 1 }
        var hits: [String] = []
        for re in bannedCalls {
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                hits.append("line \(line(m.range.location)): \(re.pattern)")
            }
        }
        // renameatx_np( ... ): take the balanced argument list and look for RENAME_EXCL in it.
        let call = try! NSRegularExpression(pattern: #"renameatx_np\s*\("#)
        let chars = Array(code.utf16)
        for m in call.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            var depth = 1, k = m.range.location + m.range.length
            let start = k
            while k < chars.count, depth > 0 {
                if chars[k] == 40 { depth += 1 } else if chars[k] == 41 { depth -= 1 }
                k += 1
            }
            let args = ns.substring(with: NSRange(location: start, length: max(0, k - 1 - start)))
            if !args.contains("RENAME_EXCL") { hits.append("line \(line(m.range.location)): renameatx_np without RENAME_EXCL") }
        }
        return hits
    }

    /// The scanner itself: each of these lines must be caught, including a write split over
    /// lines and a call after a string that holds "//".
    func testBannedCallScannerCatchesEveryForm() {
        let bad = [
            #"try data.write(to: url)"#,
            #"try data.write(to: url, options: .atomic)"#,
            #"try (data as NSData).write(toFile: path, atomically: true)"#,
            #"try text.write(toFile: path, atomically: true, encoding: .utf8)"#,
            #"FileManager.default.createFile(atPath: path, contents: data)"#,
            #"let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)"#,
            #"renamex_np(from, to, 0)"#,
            #"renameatx_np(dirfd, from, dirfd, to, 0)"#,
            #"renameatx_np(dirfd, from, dirfd, to, UInt32(RENAME_SWAP))"#,
            #"let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)"#,
            #"let h = try FileHandle(forWritingTo: url)"#,
            #"let base = "file://host"; try data.write(to: url)"#,
            "try data\n    .write(\n        to: url)",
            #"copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL))"#,
            #"Darwin.rename(a, b)"#,
            #"try fm.moveItem(at: a, to: b)"#,
            #"let s = "\(try? data.write(to: url))""#,
        ]
        for b in bad { XCTAssertFalse(Self.bannedCallsIn(b).isEmpty, "missed: \(b)") }
        let fine = [
            #"// try data.write(to: url) is banned"#,
            #"let msg = "never call rename( or O_TRUNC here""#,
            #"renameatx_np(dirfd, from, dirfd, to, UInt32(RENAME_EXCL))"#,
            #"Foundation.write(fd, bytes, count)"#,
            "/* moveItem */ let x = 1",
        ]
        for f in fine { XCTAssertEqual(Self.bannedCallsIn(f), [], "false alarm: \(f)") }
    }

    /// Rule 28: no file in Sources/CheapshotCore/Redact/ (and RedactCommand.swift, once P11 adds
    /// it) calls something that can replace an existing name. A race-free test cannot catch
    /// moveItem's check-then-rename, so this reads the source.
    func testRedactSourcesUseNoReplacingFileCalls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let redactDir = root.appendingPathComponent("Sources/CheapshotCore/Redact", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: redactDir.path) else {
            // The iOS Simulator may not see the source tree; the macOS run always does.
            throw XCTSkip("source folder not readable here: \(redactDir.path)")
        }
        XCTAssertTrue(names.contains("Publish.swift"))
        var files = names.filter { $0.hasSuffix(".swift") }.map { redactDir.appendingPathComponent($0) }
        let command = root.appendingPathComponent("Sources/CheapshotCLI/RedactCommand.swift")
        if fm.fileExists(atPath: command.path) { files.append(command) }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for hit in Self.bannedCallsIn(text) { XCTFail("\(file.lastPathComponent) \(hit)") }
        }
    }
}
