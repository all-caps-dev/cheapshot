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

    // MARK: - Word-cell statistics (the pure half of OCR.wordCells)

    /// Five monospace words at 8 px per character, one of them wide, so the median is unmoved and
    /// the coefficient of variation is the population standard deviation over the mean.
    func testCellStatisticsMedianAndVariation() {
        let words: [(width: CGFloat, count: Int)] = [(32, 4), (40, 5), (24, 3), (48, 6), (80, 8)]
        let stats = OCR.cellStatistics(words: words, lineWidth: 400)
        XCTAssertEqual(stats?.width, 8, "the cell is the median per-word cell, not the mean")
        // Cells are 8, 8, 8, 8, 10: mean 8.4, population sd 0.8, cv 0.8 / 8.4.
        XCTAssertEqual(stats?.variation ?? -1, 0.8 / 8.4, accuracy: 1e-9)
    }

    func testCellStatisticsPerfectlyFixedWidthHasZeroVariation() {
        let words: [(width: CGFloat, count: Int)] = [(24, 3), (40, 5), (56, 7)]
        let stats = OCR.cellStatistics(words: words, lineWidth: 200)
        XCTAssertEqual(stats?.width, 8)
        XCTAssertEqual(stats?.variation, 0)
    }

    /// Words under three characters, a box wider than 90% of the line, and a non-positive or
    /// non-finite width all drop out before the statistics; fewer than three survivors is nil.
    func testCellStatisticsFilters() {
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5)], lineWidth: 200), "two words are no evidence")
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5), (16, 2), (8, 1)], lineWidth: 200),
                     "short words must not count toward the three-word minimum")
        // The short-word cutoff is one constant, shared with the Vision walk in wordCells so the
        // box lookup is skipped for the same words the statistics would drop.
        let short = (width: CGFloat(8 * (OCR.minimumWordChars - 1)), count: OCR.minimumWordChars - 1)
        let long = (width: CGFloat(8 * OCR.minimumWordChars), count: OCR.minimumWordChars)
        XCTAssertNil(OCR.cellStatistics(words: [long, long, short], lineWidth: 200),
                     "a word one under minimumWordChars counted as a cell")
        XCTAssertEqual(OCR.cellStatistics(words: [long, long, long], lineWidth: 200)?.width, 8)
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5), (190, 10)], lineWidth: 200),
                     "a box wider than 90% of the line is Vision handing back the line box")
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5), (0, 4)], lineWidth: 200), "a zero-width word is not a cell")
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5), (.nan, 4)], lineWidth: 200), "a NaN width is not a cell")
        XCTAssertNil(OCR.cellStatistics(words: [(24, 3), (40, 5), (.infinity, 4)], lineWidth: 200), "an infinite width is not a cell")
        XCTAssertNil(OCR.cellStatistics(words: [], lineWidth: 200))
        // Exactly 90% of the line still counts; the filtered set of three is enough.
        let edge = OCR.cellStatistics(words: [(24, 3), (40, 5), (180, 10), (16, 2)], lineWidth: 200)
        XCTAssertEqual(edge?.width, 8)
    }
}
