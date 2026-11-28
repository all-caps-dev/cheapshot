// Swift. Redact.publish (CHE-73, redact engine plan P4, fail-closed rules 22 to 28): gives bytes
// that are already redacted and checked their final file name, without ever replacing a file.
//
// The steps, all through one descriptor for the destination folder:
//   1. refuse a bad name, a missing folder, or a final path that is one of the run's inputs;
//   2. write a temp file (O_EXCL | O_NOFOLLOW, mode 0600) in that folder and run `verify` on it;
//   3. give it the final name with a call that refuses an existing name: linkat, else
//      renameatx_np(RENAME_EXCL), else an O_EXCL | O_NOFOLLOW create at the final name;
//   4. remove the temp file on every path except a successful rename (which used it up).
//
// Banned here (rule 28): Data.write(to:), FileManager.replaceItem / moveItem / copyItem and plain
// rename. Each of those can replace a file that already has the name.
//
// Core, not Portable: POSIX calls on a descriptor. No AppKit and no Process, so it builds and its
// tests run on the iOS Simulator too.
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// The redact engine's namespace. Publish.swift declares it; Redact.swift (P8) extends it, so the
/// two PRs never create the same file.
public enum Redact {}

extension Redact {
    /// Why publish wrote nothing under the final name.
    public enum PublishError: Error, Equatable, CustomStringConvertible {
        /// Something (a file, a folder, a symlink) already has the final name. It was not touched.
        case clash(URL)
        /// The final path is one of the inputs: same path, same file by another path, or the
        /// same name in another case or Unicode spelling.
        case isInput(URL)
        /// The name or folder cannot be used: bad characters, a missing folder, not a file URL.
        case unsafeDestination(String)
        /// A file call failed. The text is the call and the system's reason.
        case write(String)
        /// The caller's `verify` closure threw. The text is its error.
        case verifyFailed(String)

        public var description: String {
            switch self {
            case .clash(let url): return "\(url.path) already exists; nothing was replaced"
            case .isInput(let url): return "\(url.path) is one of the inputs; an output never replaces an input"
            case .unsafeDestination(let why): return "unsafe destination: \(why)"
            case .write(let why): return "could not write the output: \(why)"
            case .verifyFailed(let why): return "the output failed its check before publishing: \(why)"
            }
        }
    }

    /// What landed on disk: where, how many bytes, and their SHA-256 (lowercase hex).
    public struct Published: Equatable {
        public let url: URL
        public let bytes: Int
        public let sha256: String
    }

    /// The file calls publish makes that a test needs to fail on purpose. Every call gets the
    /// folder descriptor and names inside that folder, never a full path.
    struct PublishOps {
        /// linkat(dirfd, temp, dirfd, name, 0): 0, or -1 with errno set.
        var link: (Int32, String, String) -> Int32
        /// renameatx_np(dirfd, temp, dirfd, name, RENAME_EXCL): 0, or -1 with errno set.
        var renameExcl: (Int32, String, String) -> Int32
        /// write(fd, bytes, count): bytes written, or -1 with errno set.
        var write: (Int32, UnsafeRawPointer, Int) -> Int
        /// The temp file's name. A test fixes it to plant something there first.
        var tempName: () -> String

        static let live = PublishOps(
            link: { dirfd, from, to in
                // Flags 0: a symlink as the source is not followed (the temp is a plain file anyway).
                linkat(dirfd, from, dirfd, to, 0)
            },
            renameExcl: { dirfd, from, to in
                #if canImport(Darwin)
                // Darwin only (macOS 10.12+, iOS 10+). RENAME_EXCL fails with EEXIST instead of replacing.
                return renameatx_np(dirfd, from, dirfd, to, UInt32(RENAME_EXCL))
                #else
                errno = ENOTSUP
                return -1
                #endif
            },
            write: { fd, bytes, count in Foundation.write(fd, bytes, count) },
            tempName: { ".cheapshot-\(UUID().uuidString).tmp" }
        )
    }

    /// Swapped by tests only (PublishTests), and put back after each one.
    nonisolated(unsafe) static var publishOps = PublishOps.live

    /// Writes `data` under `final` without replacing anything. The folder must exist (publish makes
    /// none) and `final` must be that folder plus one name. `verify` runs on the temp file, which
    /// already holds every byte, before the file gets its name; if it throws, nothing is published.
    public static func publish(_ data: Data, to final: URL, inputs: [URL],
                               verify: (URL) throws -> Void = { _ in }) throws -> Published {
        let ops = publishOps

        // 1. The name, taken once from lastPathComponent and never decoded again (rule 22).
        guard final.isFileURL else { throw PublishError.unsafeDestination("not a file path: \(final.absoluteString)") }
        guard !final.hasDirectoryPath else { throw PublishError.unsafeDestination("\(final.path) names a folder") }
        let name = final.lastPathComponent
        try checkName(name)
        let folder = final.deletingLastPathComponent()

        // 2. One descriptor for the folder; every later call is relative to it (rule 26). open()
        // follows a symlinked folder on purpose: ~/Dropbox is one. O_DIRECTORY refuses a file.
        let dirfd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirfd >= 0 else {
            let e = errno
            if e == ENOENT { throw PublishError.unsafeDestination("folder does not exist: \(folder.path)") }
            throw PublishError.unsafeDestination("cannot open folder \(folder.path): \(reason(e))")
        }
        defer { close(dirfd) }

        // 3. Never an input (rule 24), then a cheap early clash check so a caller walking name
        // candidates skips verify for a name that is plainly taken. The link in step 6 is still
        // what guarantees nothing is replaced; this check is only a shortcut.
        try refuseInputs(dirfd: dirfd, folder: folder, name: name, final: final, inputs: inputs)
        var st = stat()
        if fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { throw PublishError.clash(final) }
        guard errno == ENOENT else { throw PublishError.write("cannot check \(final.path): \(reason(errno))") }

        // 4. The temp file: a fresh name in the same folder (so a link or rename never crosses a
        // volume), O_EXCL so it is new, O_NOFOLLOW so a planted symlink is refused, mode 0600.
        let tempName = ops.tempName()
        let fd = openat(dirfd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PublishError.write("cannot create a temp file in \(folder.path): \(reason(errno))") }
        defer { close(fd) }
        // Rule 27: the temp name goes on every path. A successful rename sets this to false,
        // because the temp name no longer exists then.
        var tempNameExists = true
        defer { if tempNameExists { unlinkat(dirfd, tempName, 0) } }

        guard writeAll(data, to: fd, ops: ops) else { throw PublishError.write("short write") }

        // 5. The caller's check, on the bytes as they are on disk.
        do {
            try verify(folder.appendingPathComponent(tempName))
        } catch {
            throw PublishError.verifyFailed(String(describing: error))
        }

        // 6. The final name, by a call that cannot replace (rule 25). EEXIST at any step is a clash.
        // Only "this volume does not support that call" moves on to the next step; any other error
        // stops, so a real failure is reported, not papered over.
        if ops.link(dirfd, tempName, name) == 0 {
            // Same inode under two names; the deferred unlink drops the temp name.
            makeShared(fd)
        } else {
            let linkErr = errno
            if linkErr == EEXIST { throw PublishError.clash(final) }
            guard linkUnsupported(linkErr) else { throw PublishError.write("link: \(reason(linkErr))") }

            if ops.renameExcl(dirfd, tempName, name) == 0 {
                tempNameExists = false
                makeShared(fd)
            } else {
                let renameErr = errno
                if renameErr == EEXIST { throw PublishError.clash(final) }
                guard renameUnsupported(renameErr) else { throw PublishError.write("rename: \(reason(renameErr))") }
                // Last resort: write the same bytes again into a new file at the final name.
                try createExclusive(data, dirfd: dirfd, name: name, final: final, ops: ops)
            }
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Published(url: final, bytes: data.count, sha256: digest)
    }

    // MARK: pieces

    /// Rule 23 at the last step: no empty name, no "." or "..", no "/" and no control character
    /// (NUL, newline, escape and the rest of Unicode's Cc class).
    static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != ".." else {
            throw PublishError.unsafeDestination("not a file name: \"\(name)\"")
        }
        guard !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw PublishError.unsafeDestination("file name holds a slash or a control character")
        }
    }

    /// Rule 24: the final path is refused when it is an input by resolved path (case-folded and
    /// NFC, so APFS's one-name-for-both cannot slip through) or, when something is already there,
    /// by device and inode (a hard link or a symlink to an input).
    private static func refuseInputs(dirfd: Int32, folder: URL, name: String, final: URL, inputs: [URL]) throws {
        guard !inputs.isEmpty else { return }
        // The folder's real path, from the descriptor itself, so the check is about the folder
        // publish will write into, not a path that could be swapped in between.
        let folderPath = descriptorPath(dirfd) ?? resolved(folder.path)
        let finalKey = pathKey((folderPath as NSString).appendingPathComponent(name))
        var target = stat()
        // Follows a symlink on purpose: a symlink at the final name that points at an input is
        // reported as the input. (It would be a clash anyway.)
        let targetExists = fstatat(dirfd, name, &target, 0) == 0
        for input in inputs {
            if pathKey(resolved(input.path)) == finalKey { throw PublishError.isInput(final) }
            var s = stat()
            if targetExists, stat(input.path, &s) == 0, s.st_dev == target.st_dev, s.st_ino == target.st_ino {
                throw PublishError.isInput(final)
            }
        }
    }

    /// The comparison form of a path: case-folded. NFC and NFD spellings need no extra step:
    /// a file URL already stores one spelling of each name, and Swift's String == compares by
    /// canonical equivalence anyway ("é" equals "e" + U+0301). PublishTests pins the NFD case.
    private static func pathKey(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil)
    }

    /// realpath(3) of a path. For one that does not exist (an input deleted since it was read),
    /// the nearest folder above it that does exist is resolved and the rest is put back on, so
    /// /var/... and /private/var/... still compare equal.
    private static func resolved(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let p = realpath(url.path, nil) {
            defer { free(p) }
            return String(cString: p)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }   // reached "/"
        return (resolved(parent.path) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// The path the kernel has for an open descriptor (F_GETPATH, Darwin), symlinks resolved.
    private static func descriptorPath(_ fd: Int32) -> String? {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    /// Writes every byte, looping over partial writes. False on an error or a write of 0 bytes.
    private static func writeAll(_ data: Data, to fd: Int32, ops: PublishOps) -> Bool {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard var p = buf.baseAddress else { return true }   // empty data: nothing to write
            var left = buf.count
            while left > 0 {
                let n = ops.write(fd, p, left)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                p += n
                left -= n
            }
            return true
        }
    }

    /// The published file is meant to be shared, so it gets the mode a new file gets under this
    /// process's umask (0644 under the usual 022) instead of the temp file's 0600. If fchmod fails,
    /// the file stays 0600, which is stricter, so that is not an error.
    private static func makeShared(_ fd: Int32) {
        _ = fchmod(fd, sharedMode())
    }

    /// 0666 minus the umask. POSIX has no call that only reads the umask, so this sets and restores
    /// it. That is process-wide: fine for the CLI, a brief window in a threaded app (plan section 7).
    private static func sharedMode() -> mode_t {
        let mask = umask(0)
        umask(mask)
        return 0o666 & ~mask
    }

    /// Hard links refused by this volume (exFAT, some network shares): try the next step.
    private static func linkUnsupported(_ e: Int32) -> Bool {
        e == ENOTSUP || e == EOPNOTSUPP || e == EPERM || e == EMLINK || e == EXDEV
    }

    /// RENAME_EXCL refused by this volume: try the exclusive create.
    private static func renameUnsupported(_ e: Int32) -> Bool {
        e == ENOTSUP || e == EOPNOTSUPP || e == EINVAL || e == EPERM || e == EXDEV
    }

    /// The last fallback: a new file at the final name (O_EXCL | O_NOFOLLOW, so an existing name or
    /// a symlink is a clash), mode 0666 under the umask. A failed write removes the file, but only
    /// if the name still points at the file this call created.
    private static func createExclusive(_ data: Data, dirfd: Int32, name: String, final: URL, ops: PublishOps) throws {
        let out = openat(dirfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard out >= 0 else {
            let e = errno
            // O_NOFOLLOW on a symlink gives ELOOP; it is still a name that already exists.
            if e == EEXIST || e == ELOOP { throw PublishError.clash(final) }
            throw PublishError.write("create: \(reason(e))")
        }
        defer { close(out) }
        guard writeAll(data, to: out, ops: ops) else {
            var mine = stat(), there = stat()
            if fstat(out, &mine) == 0, fstatat(dirfd, name, &there, AT_SYMLINK_NOFOLLOW) == 0,
               mine.st_dev == there.st_dev, mine.st_ino == there.st_ino {
                unlinkat(dirfd, name, 0)
            }
            throw PublishError.write("short write")
        }
    }

    /// The system's words for an errno value.
    private static func reason(_ e: Int32) -> String { String(cString: strerror(e)) }
}
