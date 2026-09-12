import XCTest
@testable import CheapshotCore

/// Builds a 4 s, 10 fps clip with four solid-colour segments (three changes). Verified on
/// ffmpeg 9.0.1: the Phase 1 chain prints 3 frames (t = 0, 2, 3; the red->green change at t = 1
/// scores under 0.25) and writes exactly 3 files. The old chain wrote 39 files for 3 frames.
final class FFmpegFrameSourceTests: XCTestCase {
    var tmp: URL!
    var clip: URL!

    override func setUpWithError() throws {
        guard let ff = FFmpegFrameSource.findFFmpeg() else { throw XCTSkip("ffmpeg not installed") }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ffsrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clip = tmp.appendingPathComponent("clip.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "color=c=red:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=green:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=white:s=320x240:r=10:d=1",
                       "-filter_complex", "[0][1][2][3]concat=n=4:v=1:a=0", "-pix_fmt", "yuv420p", clip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    override func tearDownWithError() throws { if let tmp = tmp { try? FileManager.default.removeItem(at: tmp) } }

    func leftoverDirs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix("cheapshot-") }
    }

    func testThreeChangesYieldThreeFramesAndNoLeftoverDir() async throws {
        let source = FFmpegFrameSource(tempBase: tmp)
        var times: [TimeInterval] = []
        var sizes: [(Int, Int)] = []
        for try await frame in try source.frames(of: clip, maxFrames: 200) {
            times.append(frame.time); sizes.append((frame.image.width, frame.image.height))
        }
        XCTAssertEqual(times.count, 3, "times: \(times)")
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(sizes.allSatisfy { $0 == (320, 240) })
        XCTAssertEqual(try leftoverDirs(), [], "temp dir must be deleted when the stream finishes")
    }

    func testMaxFramesCapsKeptFrames() async throws {
        var n = 0
        for try await _ in try FFmpegFrameSource(tempBase: tmp).frames(of: clip, maxFrames: 2) { n += 1 }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try leftoverDirs(), [])
    }

    func testMissingVideoThrowsAndLeavesNothing() async throws {
        do {
            for try await _ in try FFmpegFrameSource(tempBase: tmp).frames(of: tmp.appendingPathComponent("nope.mp4"), maxFrames: 5) {}
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(try leftoverDirs(), [])
    }

    func testFilterChainMatchesSpec() {
        XCTAssertEqual(FFmpegFrameSource.filterChain(threshold: 0.25),
                       "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\\,0)+gt(scene\\,0.25),metadata=print:file=-")
    }

    func testFindFFmpegFallsBackWhenPathIsEmpty() {
        XCTAssertNotNil(FFmpegFrameSource.findFFmpeg(environment: ["PATH": ""]))
    }

    func testMissingFFmpegThrows() {
        XCTAssertThrowsError(try FFmpegFrameSource(ffmpegPath: "/nonexistent/ffmpeg", tempBase: tmp).frames(of: clip, maxFrames: 1))
    }
}
