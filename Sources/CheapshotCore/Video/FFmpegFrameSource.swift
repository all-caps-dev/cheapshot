import Foundation
import CoreGraphics
import ImageIO

/// CLI frame source. Runs ffmpeg once with scene detection into a temp directory this source
/// owns, then streams the JPEGs as CGImages one at a time and deletes the directory when the
/// stream ends. Not sandbox-safe; the app uses AVFoundation (later phase).
public struct FFmpegFrameSource: FrameSource {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Owns one extraction directory. The stream's cursor holds the only reference, so the
    /// directory is removed when the stream is drained (the cursor drops it) or when a consumer
    /// stops early and the stream is released (deinit). Sendable: the URL is immutable.
    final class TempDir: Sendable {
        let url: URL
        init(base: URL) throws {
            url = base.appendingPathComponent("cheapshot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// The unfolding closure's only mutable state, behind a lock so the closure captures a
    /// Sendable reference instead of mutating vars from concurrently-executing code.
    final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: ArraySlice<(TimeInterval, URL)>
        private var dir: TempDir?
        init(_ frames: [(TimeInterval, URL)], dir: TempDir) { pending = frames[...]; self.dir = dir }

        func next() -> VideoFrame? {
            lock.lock(); defer { lock.unlock() }
            while let (t, url) = pending.popFirst() {
                if let image = FFmpegFrameSource.loadJPEG(url) { return VideoFrame(time: t, image: image) }
            }
            dir = nil   // drained: delete now rather than when the stream is eventually released
            return nil
        }
    }

    public let ffmpegPath: String?
    public let sceneThreshold: Double
    public let tempBase: URL

    public init(ffmpegPath: String? = nil, sceneThreshold: Double = 0.25,
                tempBase: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.ffmpegPath = ffmpegPath; self.sceneThreshold = sceneThreshold; self.tempBase = tempBase
    }

    /// The user's PATH first; then the usual install locations.
    public static func findFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let c = String(dir) + "/ffmpeg"
            if fm.isExecutableFile(atPath: c) { return c }
        }
        for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", NSHomeDirectory() + "/.local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// fps=4 cuts filter work about 15x on 60 fps captures; mpdecimate drops static stretches
    /// before the scene metric runs; select keeps frame 0 plus every scene change.
    public static func filterChain(threshold: Double) -> String {
        "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\\,0)+gt(scene\\,\(threshold)),metadata=print:file=-"
    }

    public func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard let ff = ffmpegPath ?? Self.findFFmpeg(), FileManager.default.isExecutableFile(atPath: ff) else {
            throw Failure(message: "ffmpeg not found on PATH, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin")
        }
        guard FileManager.default.fileExists(atPath: video.path) else { throw Failure(message: "no such video \(video.path)") }
        // On a throw below, `dir` is released on the way out and deinit removes the directory.
        let dir = try TempDir(base: tempBase)
        let extracted = try extract(ffmpeg: ff, video: video, into: dir.url, maxFrames: maxFrames)

        // Unfolding streams load one JPEG per pull, so a 200-frame 1440p recording is never all in memory.
        let cursor = Cursor(extracted, dir: dir)
        return AsyncThrowingStream(unfolding: { cursor.next() })
    }

    func extract(ffmpeg: String, video: URL, into dir: URL, maxFrames: Int) throws -> [(TimeInterval, URL)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", video.path,
                       "-an", "-sn",
                       "-vf", Self.filterChain(threshold: sceneThreshold),
                       "-fps_mode", "vfr",
                       "-frames:v", "\(maxFrames)",
                       "-q:v", "2",
                       dir.appendingPathComponent("f_%05d.jpg").path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { throw Failure(message: "could not launch \(ffmpeg): \(error.localizedDescription)") }
        // Both pipes drain concurrently so neither can fill and stall ffmpeg. stderr is read on a
        // background queue into a locked buffer; stdout is read here, so no captured var is mutated.
        let errBuf = PipeBuffer()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { errBuf.set(err.fileHandleForReading.readDataToEndOfFile()); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); g.wait()
        if p.terminationStatus != 0 {
            let tail = (String(data: errBuf.get(), encoding: .utf8) ?? "").split(separator: "\n").suffix(6).joined(separator: "\n")
            throw Failure(message: "ffmpeg exited \(p.terminationStatus)\n\(tail)")
        }

        // metadata=print emits "frame:N  pts:... pts_time:SECONDS" per kept frame, frame 0 included.
        var times: [TimeInterval] = []
        for line in (String(data: outData, encoding: .utf8) ?? "").split(separator: "\n") {
            guard let r = line.range(of: "pts_time:") else { continue }
            if let t = Double(line[r.upperBound...].prefix(while: { $0 != " " })) { times.append(t) }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.sorted()
        // A short timestamp list means the fallback below invents seconds. Say so rather than
        // handing back plausible-looking times nobody can tell from measured ones.
        if times.count < files.count {
            FileHandle.standardError.write(Data("cheapshot: ffmpeg printed \(times.count) timestamps for \(files.count) frames; later frames use their index as seconds\n".utf8))
        }
        return files.enumerated().map { i, f in (i < times.count ? times[i] : TimeInterval(i), dir.appendingPathComponent(f)) }
    }

    /// One pipe's bytes, written from the reader queue and read after the group completes.
    final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func loadJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
