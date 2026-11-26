import XCTest
import CoreGraphics
@testable import CheapshotCore

/// The cold-start retry in `OCR.checked`, driven with stub passes so no Vision call runs, and the
/// screenshot heuristic on synthetic bitmaps.
final class OCRRetryTests: XCTestCase {
    func lines(_ n: Int) -> [RenderedLine] {
        (0..<n).map { RenderedLine(n: $0 + 1, text: "line \($0)", bbox: .zero, confidence: 1, fenced: false) }
    }

    /// Runs `checked` with passes that return the given counts in order and take `seconds` each.
    func drive(_ counts: [Int], seconds: Double = 0.4, screenshotLike: Bool = true, probe: Int? = nil)
        throws -> (result: OCR.CheckedLayout, runs: Int, probes: Int) {
        var runs = 0, probes = 0, clock = 0.0
        let r = try OCR.checked(screenshotLike: screenshotLike,
                                run: { defer { runs += 1; clock += seconds }; return lines(counts[min(runs, counts.count - 1)]) },
                                probe: { probes += 1; return probe },
                                now: { clock })
        return (r, runs, probes)
    }

    func testWarmPassWithTextRunsOnceAndNeverProbes() throws {
        let d = try drive([40], probe: 40)
        XCTAssertEqual(d.runs, 1); XCTAssertEqual(d.probes, 0, "a warm pass that found text must not pay for the probe")
        XCTAssertFalse(d.result.retried); XCTAssertEqual(d.result.status, .ok)
    }

    func testEmptyScreenshotIsRetriedAndTheRetryWins() throws {
        let d = try drive([0, 40])
        XCTAssertEqual(d.runs, 2); XCTAssertTrue(d.result.retried)
        XCTAssertEqual(d.result.lines.count, 40); XCTAssertEqual(d.result.status, .ok)
    }

    func testEmptyAfterRetryReportsEmptyAndRetried() throws {
        let d = try drive([0, 0])
        XCTAssertTrue(d.result.retried); XCTAssertEqual(d.result.status, .empty)
        XCTAssertTrue(d.result.screenshotLike)
    }

    func testEmptyPhotoIsNotRetried() throws {
        let d = try drive([0, 40], screenshotLike: false)
        XCTAssertEqual(d.runs, 1); XCTAssertFalse(d.result.retried); XCTAssertEqual(d.result.status, .empty)
    }

    /// The measured failure: a cold run (41 s) that dropped 8 of 40 lines.
    func testColdShortPassIsRetried() throws {
        let d = try drive([32, 40], seconds: 41, probe: 40)
        XCTAssertEqual(d.runs, 2); XCTAssertEqual(d.probes, 1)
        XCTAssertTrue(d.result.retried); XCTAssertEqual(d.result.lines.count, 40)
    }

    func testColdFullPassIsKept() throws {
        // 81 accurate lines against 94 fast ones on the dense image: 0.86, not short.
        let d = try drive([81], seconds: 29, probe: 94)
        XCTAssertEqual(d.runs, 1); XCTAssertFalse(d.result.retried)
    }

    func testColdPassWithTooFewProbeLinesIsKept() throws {
        let d = try drive([1, 4], seconds: 29, probe: 4)
        XCTAssertFalse(d.result.retried)
    }

    func testWarmShortPassIsNotProbed() throws {
        let d = try drive([10], seconds: 0.5, probe: 40)
        XCTAssertEqual(d.probes, 0); XCTAssertFalse(d.result.retried)
    }

    func testRetryThatFindsLessKeepsTheFirstPass() throws {
        let d = try drive([32, 20], seconds: 41, probe: 40)
        XCTAssertTrue(d.result.retried); XCTAssertEqual(d.result.lines.count, 32)
    }

    func testRetryThatThrowsKeepsTheFirstPass() throws {
        var runs = 0, clock = 0.0
        struct Boom: Error {}
        let r = try OCR.checked(screenshotLike: true,
                                run: { runs += 1; clock += 41; if runs == 2 { throw Boom() }; return lines(32) },
                                probe: { 40 }, now: { clock })
        XCTAssertTrue(r.retried); XCTAssertEqual(r.lines.count, 32)
    }

    // MARK: - Screenshot heuristic

    func bitmap(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        paint(ctx)
        return try XCTUnwrap(ctx.makeImage())
    }

    /// White page with dark text bars: the shape of a terminal or settings screenshot.
    func testUIShapedImageIsScreenshotLike() throws {
        let img = try bitmap(800, 600) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            for y in stride(from: 20, to: 580, by: 30) { ctx.fill(CGRect(x: 20, y: y, width: 500, height: 12)) }
        }
        XCTAssertTrue(OCR.isScreenshotLike(img))
    }

    /// Per-pixel noise: the colour spread of a photo.
    func testNoisyImageIsNotScreenshotLike() throws {
        var rng = SystemRandomNumberGenerator()
        let img = try bitmap(400, 400) { ctx in
            for y in stride(from: 0, to: 400, by: 4) {
                for x in stride(from: 0, to: 400, by: 4) {
                    ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                             blue: .random(in: 0...1, using: &rng), alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        XCTAssertLessThan(OCR.flatColorShare(img), 0.5)
        XCTAssertFalse(OCR.isScreenshotLike(img))
    }

    func testSmallImageIsNeverScreenshotLike() throws {
        let img = try bitmap(199, 800) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 199, height: 800))
        }
        XCTAssertEqual(OCR.flatColorShare(img), 1, accuracy: 1e-9)
        XCTAssertFalse(OCR.isScreenshotLike(img), "under 200 px on a side is an icon or a crop, not a screenshot")
    }
}
