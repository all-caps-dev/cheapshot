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

    struct OCRFailed: Error {}

    /// Fake OCR keyed on frame time: the transcriber hands the closure the image, and the image
    /// is the same for every frame, so the fake counts calls instead.
    final class Counter { var n = 0 }

    static func line(_ s: String) -> RenderedLine {
        RenderedLine(n: 1, text: s, bbox: CGRect(x: 0, y: 0, width: 100, height: 10), confidence: 1, fenced: false)
    }

    func testBlankFramesCountTokensButYieldNoSegments() async throws {
        let t = try await VideoTranscriber(source: Blank()).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
        XCTAssertEqual(t.frameCount, 3)
        XCTAssertEqual(t.imageTokens, 3 * 60)   // 300*150/750 each
        XCTAssertEqual(t.segments, [])
        XCTAssertEqual(t.failedFrames, 0)
    }

    func testFailedFramesAreCountedAndPartialFailureStillSucceeds() async throws {
        let calls = Counter()
        let ocr: VideoTranscriber.OCRFunction = { _, _ in
            calls.n += 1
            if calls.n == 2 { throw OCRFailed() }
            return [Self.line("call \(calls.n)")]
        }
        let t = try await VideoTranscriber(source: Blank(), redactor: nil, ocr: ocr).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
        // The failed frame is not read: it is out of frameCount and its 60 image tokens are not "saved".
        XCTAssertEqual(t.frameCount, 2)
        XCTAssertEqual(t.failedFrames, 1)
        XCTAssertEqual(t.imageTokens, 2 * 60)
        XCTAssertEqual(t.segments.map(\.text), ["call 1", "call 3"])
    }

    func testAllFramesFailingThrows() async throws {
        let ocr: VideoTranscriber.OCRFunction = { _, _ in throw OCRFailed() }
        do {
            _ = try await VideoTranscriber(source: Blank(), redactor: nil, ocr: ocr).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
            XCTFail("expected a throw when every frame fails OCR")
        } catch let e as VideoTranscriber.Failure {
            XCTAssertTrue(e.description.contains("3"), "message should name the frame count: \(e)")
        }
    }

    func testRedactionsCountOnlyKeptFrames() async throws {
        // Three frames of the same screen: one segment survives dedupe, so the report must say one
        // email was redacted, not three. The ledger and the stats line both read this total.
        let ocr: VideoTranscriber.OCRFunction = { _, _ in [Self.line("mail me at ryan@example.com today")] }
        let t = try await VideoTranscriber(source: Blank(), ocr: ocr).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
        XCTAssertEqual(t.segments.count, 1)
        XCTAssertEqual(t.segments.first?.text, "mail me at [EMAIL] today")
        XCTAssertEqual(t.redactions.counts, ["EMAIL": 1])
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
