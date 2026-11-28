// Swift. Tests for BlankCheck (CHE-57): blank means a uniform image, not "few pixels differ".
// T10 in the plan: a ratio threshold, a bucket centre or a size overflow would each fail one of these.
import XCTest
@testable import CheapshotPortable

/// A width x height RGBA buffer filled with one colour.
private func canvas(_ width: Int, _ height: Int, _ px: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * height * 4)
    var i = 0
    while i < out.count { out[i] = px.0; out[i + 1] = px.1; out[i + 2] = px.2; out[i + 3] = px.3; i += 4 }
    return out
}

/// Sets the pixel at (x, y) to one colour.
private func setPixel(_ buf: inout [UInt8], width: Int, x: Int, y: Int, _ px: (UInt8, UInt8, UInt8, UInt8)) {
    let i = (y * width + x) * 4
    buf[i] = px.0; buf[i + 1] = px.1; buf[i + 2] = px.2; buf[i + 3] = px.3
}

final class BlankCheckTests: XCTestCase {
    func testUniformWhiteAndUniformDarkAreBlank() {
        XCTAssertTrue(BlankCheck.isBlank(rgba: canvas(480, 360, (255, 255, 255, 255)), width: 480, height: 360))
        XCTAssertTrue(BlankCheck.isBlank(rgba: canvas(480, 360, (18, 18, 20, 255)), width: 480, height: 360))
        XCTAssertTrue(BlankCheck.isBlank(rgba: canvas(1, 1, (0, 0, 0, 0)), width: 1, height: 1), "one pixel is uniform")
    }

    /// 3840 x 2160 white with one 400-pixel dark run (0.005% of pixels), placed on the last row so a
    /// ratio or a dominant-colour count over the whole image would call it blank.
    func testOneShortLineOnA4KCanvasIsNotBlank() {
        let w = 3840, h = 2160
        var buf = canvas(w, h, (255, 255, 255, 255))
        for x in 1000..<1400 { setPixel(&buf, width: w, x: x, y: h - 1, (30, 30, 30, 255)) }
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: w, height: h))
    }

    /// Faint text: grey 242 on white 255. Every Spark attempt's tolerance of 24 called this blank.
    func testFaintGrey242OnWhiteIsNotBlank() {
        let w = 480, h = 360
        var buf = canvas(w, h, (255, 255, 255, 255))
        for y in 100..<120 { for x in 40..<300 { setPixel(&buf, width: w, x: x, y: y, (242, 242, 242, 255)) } }
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: w, height: h))
    }

    /// Plus or minus 2 from the first pixel on every channel is blank; one pixel 3 away on one channel is not.
    /// Measured from the first pixel, not from a bucket centre.
    func testNoiseWithinToleranceIsBlankAndOneStepOverIsNot() {
        let w = 64, h = 48
        let base: (UInt8, UInt8, UInt8, UInt8) = (128, 128, 128, 200)
        var buf = canvas(w, h, base)
        // Deterministic noise in -2...2 on all four channels, every pixel but the first.
        var i = 4
        var step = 0
        while i < buf.count {
            let d = Int(step % 5) - 2          // -2, -1, 0, 1, 2
            for c in 0..<4 { buf[i + c] = UInt8(Int(buf[i + c]) + (c % 2 == 0 ? d : -d)) }
            i += 4; step += 1
        }
        XCTAssertTrue(BlankCheck.isBlank(rgba: buf, width: w, height: h), "noise within 2 is blank")

        var over = buf
        setPixel(&over, width: w, x: w - 1, y: h - 1, (131, 128, 128, 200))   // red 3 above the first pixel
        XCTAssertFalse(BlankCheck.isBlank(rgba: over, width: w, height: h), "3 over is not blank")

        var under = buf
        setPixel(&under, width: w, x: 5, y: 7, (128, 128, 128, 197))         // alpha 3 below
        XCTAssertFalse(BlankCheck.isBlank(rgba: under, width: w, height: h), "alpha counts too")

        // The tolerance argument is honoured: at 0, the noise is no longer blank.
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: w, height: h, tolerance: 0))
        XCTAssertEqual(BlankCheck.tolerance, 2)
    }

    /// Sizes that do not describe the buffer are not blank, and huge sizes return false instead of trapping.
    func testMismatchedOrOverflowingSizeIsNotBlank() {
        let buf = canvas(10, 10, (255, 255, 255, 255))
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: 10, height: 9), "too many bytes")
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: 10, height: 11), "too few bytes")
        XCTAssertFalse(BlankCheck.isBlank(rgba: Array(buf.dropLast()), width: 10, height: 10), "not a whole pixel")
        XCTAssertFalse(BlankCheck.isBlank(rgba: [], width: 0, height: 0), "empty")
        XCTAssertFalse(BlankCheck.isBlank(rgba: [], width: 0, height: 10), "zero width")
        XCTAssertFalse(BlankCheck.isBlank(rgba: [], width: 10, height: 0), "zero height")
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: -10, height: -10), "negative sizes")
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: Int.max, height: Int.max), "overflow")
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: Int.max, height: 1), "overflow on the times 4")
        XCTAssertFalse(BlankCheck.isBlank(rgba: buf, width: Int.max / 4 + 1, height: 1), "overflow on the times 4")
    }
}
