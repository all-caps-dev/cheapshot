import XCTest
@testable import CheapshotCore

final class VideoTranscriberTests: XCTestCase {
    struct Blank: FrameSource {
        func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error> {
            AsyncThrowingStream { c in
                let ctx = CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
                let img = ctx.makeImage()!
                for t in [0.0, 2.0, 3.0] { c.yield(VideoFrame(time: t, image: img)) }
                c.finish()
            }
        }
    }

    func testBlankFramesCountTokensButYieldNoSegments() async throws {
        let t = try await VideoTranscriber(source: Blank()).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
        XCTAssertEqual(t.frameCount, 3)
        XCTAssertEqual(t.imageTokens, 3 * 60)   // 300*150/750 each
        XCTAssertEqual(t.segments, [])
    }

    func testSimilarityAndStamp() {
        XCTAssertEqual(VideoTranscriber.similarity("a b c", "a b c"), 1)
        XCTAssertEqual(VideoTranscriber.similarity("a b c d", "a b"), 0.5)
        XCTAssertEqual(VideoTranscriber.similarity("", ""), 1)
        XCTAssertEqual(VideoTranscriber.similarity("a", ""), 0)
        XCTAssertEqual(VideoTranscriber.stamp(75.4), "01:15")
        XCTAssertEqual(VideoTranscriber.stamp(0), "00:00")
    }
}
