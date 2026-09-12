import XCTest
import CoreGraphics
@testable import CheapshotCore

/// Vision hands back normalized rects with a bottom-left origin; everything downstream of
/// `OCR.perform` is pixels with a top-left origin. These two conversions have to be exact
/// inverses, because the regionOfInterest pass runs a box through both.
final class OCRGeometryTests: XCTestCase {
    func assertRoundTrips(_ r: CGRect, width: Int, height: Int, line: UInt = #line) {
        let back = OCR.normalized(OCR.pixels(r, width: width, height: height), width: width, height: height)
        XCTAssertEqual(back.minX, r.minX, accuracy: 1e-9, "minX", line: line)
        XCTAssertEqual(back.minY, r.minY, accuracy: 1e-9, "minY", line: line)
        XCTAssertEqual(back.width, r.width, accuracy: 1e-9, "width", line: line)
        XCTAssertEqual(back.height, r.height, accuracy: 1e-9, "height", line: line)
    }

    func testNormalizedIsTheInverseOfPixels() {
        assertRoundTrips(CGRect(x: 0.125, y: 0.165, width: 0.33, height: 0.085), width: 800, height: 400)
        assertRoundTrips(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), width: 1280, height: 720)
    }

    func testPixelsFlipsToATopLeftOrigin() {
        // The top-left quadrant in Vision's coordinates: x from 0, y from 0.75 up to 1.
        let r = OCR.pixels(CGRect(x: 0, y: 0.75, width: 0.5, height: 0.25), width: 800, height: 400)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 400, height: 100))
    }
}
