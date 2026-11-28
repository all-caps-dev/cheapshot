// Swift. Tests for MetadataScrubJPEG (CHE-52, plan section 3.5 and P2 in section 5).
//
// Every fixture is a hand-built list of JPEG segments: no ImageIO, no image files, so the suite
// runs on Windows and on the iOS Simulator. The bytes are not a decodable picture; the scrubber
// only reads structure (markers, lengths, scan bytes), so structure is all a fixture needs.
import Foundation
import XCTest
@testable import CheapshotPortable

/// Building blocks for fixtures. `seg` writes one length-prefixed segment: FF, marker, a 2-byte
/// big-endian length that counts itself (so payload + 2), then the payload.
private enum J {
    static let soi: [UInt8] = [0xFF, 0xD8]
    static let eoi: [UInt8] = [0xFF, 0xD9]

    static func seg(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// APP0 JFIF: "JFIF\0", version 1.1, units 0, density 1x1, then the two thumbnail sizes and
    /// width * height * 3 bytes of thumbnail pixels. With both sizes 0 this is the one APP0 kept.
    static func jfif(thumbW: UInt8 = 0, thumbH: UInt8 = 0, extra: [UInt8] = []) -> [UInt8] {
        let pixels = [UInt8](repeating: 0x7F, count: Int(thumbW) * Int(thumbH) * 3)
        return seg(0xE0, ascii("JFIF") + [0, 1, 1, 0, 0, 1, 0, 1, thumbW, thumbH] + pixels + extra)
    }

    /// APP0 JFXX with extension code 0x10: a whole JPEG thumbnail inside the segment. The inner
    /// SOI and EOI sit inside the length, so a correct walk steps over them.
    static let jfxx = seg(0xE0, ascii("JFXX") + [0, 0x10] + soi + [0x01, 0x02, 0x03] + eoi)
    /// APP0 that only looks like JFIF: no NUL after the identifier.
    static let fakeJFIF = seg(0xE0, ascii("JFIF") + [0x20, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    static let junkAPP0 = seg(0xE0, ascii("hello"))

    static let exif = seg(0xE1, ascii("Exif") + [0, 0] + ascii("MM") + [0, 0x2A] + ascii("GPS 40.7N 73.9W"))
    static let xmp = seg(0xE1, ascii("http://ns.adobe.com/xap/1.0/") + [0] + ascii("<x:xmpmeta>owner</x:xmpmeta>"))
    static let icc = seg(0xE2, ascii("ICC_PROFILE") + [0, 1, 1] + [UInt8](repeating: 0x42, count: 24))
    static let iccNoNUL = seg(0xE2, ascii("ICC_PROFILE") + [0x20, 1, 1, 0x42])
    static let mpf = seg(0xE2, ascii("MPF") + [0] + ascii("MM") + [0, 0x2A, 0, 0, 0, 8])
    static let flashpix = seg(0xE2, ascii("FPXR") + [0, 0, 1, 2, 3])
    static let app13 = seg(0xED, ascii("Photoshop 3.0") + [0] + ascii("8BIM caption"))
    static let com = seg(0xFE, ascii("written by someone"))

    static let dqt = seg(0xDB, [0x00] + [UInt8](repeating: 1, count: 64))
    static let dri = seg(0xDD, [0x00, 0x04])
    /// One Huffman table: 16 counts (one code of length 1) and its one symbol.
    static let dht = seg(0xC4, [0x00, 1] + [UInt8](repeating: 0, count: 15) + [0x00])
    static let dht2 = seg(0xC4, [0x10, 1] + [UInt8](repeating: 0, count: 15) + [0x01])
    /// A frame header with one component: precision 8, 16 x 16, Nf 1, length 8 + 3 * Nf = 11.
    static func sof(_ marker: UInt8 = 0xC0) -> [UInt8] { seg(marker, [8, 0, 16, 0, 16, 1, 1, 0x11, 0]) }
    /// A scan header with one component: Ns 1, length 6 + 2 * Ns = 8.
    static let sos = seg(0xDA, [1, 1, 0x00, 0, 63, 0])
    /// Entropy data with a stuffed byte (FF 00) and a restart marker (FF D3), both of which are
    /// data inside a scan and must not end it.
    static let scan: [UInt8] = [0x12, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD3, 0x78, 0x9A]
    static let scan2: [UInt8] = [0x21, 0xFF, 0x00, 0x43]
    static let scan3: [UInt8] = [0x65, 0xFF, 0xD7, 0x87, 0xFF, 0x00]

    /// The body after the APP segments: tables, frame, one scan, EOI.
    static let body: [UInt8] = dqt + sof() + dht + sos + scan + eoi

    /// A whole baseline file with the given APP/COM segments after SOI.
    static func jpeg(_ head: [[UInt8]] = [jfif()]) -> [UInt8] { soi + head.flatMap { $0 } + body }
}

final class MetadataScrubJPEGTests: XCTestCase {
    private typealias S = MetadataScrubJPEG

    /// Runs strip and returns the bytes, failing the test (not crashing) if it throws.
    private func stripped(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> [UInt8]? {
        do { return [UInt8](try S.strip(Data(bytes))) } catch {
            XCTFail("strip threw \(error)", file: file, line: line)
            return nil
        }
    }

    /// Asserts strip throws exactly `expected`.
    private func assertThrows(_ bytes: [UInt8], _ expected: S.ScrubError, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try S.strip(Data(bytes)), label, file: file, line: line) { error in
            XCTAssertEqual(error as? S.ScrubError, expected, label, file: file, line: line)
        }
    }

    /// The (kind, marker, offset) triples check reports, for compact comparisons.
    private func found(_ bytes: [UInt8]) -> [String] {
        S.check(Data(bytes)).map { "\($0.kind.rawValue) \(String($0.marker, radix: 16)) @\($0.offset)" }
    }

    // M8: the stripper must never hand back its input. Exif and XMP live in APP1.
    func testStripRemovesAPP1AndNeverReturnsItsInput() {
        let input = J.jpeg([J.jfif(), J.exif, J.xmp])
        let golden = J.jpeg([J.jfif()])
        guard let out = stripped(input) else { return }
        XCTAssertEqual(out, golden, "byte-golden: SOI, JFIF, tables, frame, scan, EOI; both APP1 gone")
        XCTAssertNotEqual(out, input)
        XCTAssertFalse(out.count == input.count, "nothing was removed")

        // check on the unstripped file names both APP1 segments, by offset.
        let exifAt = 2 + J.jfif().count
        XCTAssertEqual(found(input), ["segment e1 @\(exifAt)", "segment e1 @\(exifAt + J.exif.count)"])
        XCTAssertEqual(found(out), [])

        // A Data slice whose indices do not start at 0 gives the same answer.
        let sliced = (Data([0xAA, 0xBB]) + Data(input)).dropFirst(2)
        XCTAssertEqual(try [UInt8](S.strip(sliced)), golden)
        XCTAssertEqual(S.check(sliced).count, 2)

        // APP13 (Photoshop IPTC) and COM go the same way.
        XCTAssertEqual(stripped(J.jpeg([J.jfif(), J.app13, J.com])), golden)
    }

    // M8, T3: anything the walk cannot fully parse throws; a length is never trusted past the end.
    func testMalformedOrTruncatedInputThrows() {
        let head = J.soi + J.jfif()
        let at = head.count   // offset of the segment after JFIF
        let cases: [(String, [UInt8], S.ScrubError)] = [
            ("empty", [], .notJPEG),
            ("one byte", [0xFF], .notJPEG),
            ("no SOI", [0x00, 0x01] + J.body, .notJPEG),
            ("SOI only", J.soi, .missingEOI),
            ("length 1", head + [0xFF, 0xE1, 0x00, 0x01] + J.body, .malformed(offset: at)),
            ("length 0", head + [0xFF, 0xDB, 0x00, 0x00] + J.body, .malformed(offset: at)),
            ("length past the end", head + [0xFF, 0xE1, 0x40, 0x00] + J.body, .truncated(offset: at)),
            ("length field cut", head + [0xFF, 0xE1, 0x00], .truncated(offset: at)),
            ("marker cut after FF", head + [0xFF], .truncated(offset: at)),
            ("cut inside a segment", Array(J.jpeg().prefix(at + 10)), .truncated(offset: at)),
            ("cut mid-scan", Array(J.jpeg().dropLast(4)), .missingEOI),
            ("cut on a scan FF", Array(J.jpeg().dropLast(1)), .missingEOI),
            ("no EOI", Array(J.jpeg().dropLast(2)), .missingEOI),
            ("no EOI in segment space", head + J.dqt, .missingEOI),
            ("no SOF before SOS", head + J.dqt + J.dht + J.sos + J.scan + J.eoi, .missingFrame),
            ("no SOF at all", head + J.dqt + J.eoi, .missingFrame),
            ("two SOF", head + J.dqt + J.sof() + J.sof(0xC1) + J.dht + J.sos + J.scan + J.eoi,
             .malformed(offset: at + J.dqt.count + J.sof().count)),
            ("frame but no scan", head + J.dqt + J.sof() + J.eoi, .malformed(offset: at + J.dqt.count + J.sof().count)),
            ("SOF length disagrees with Nf", head + J.seg(0xC0, [8, 0, 16, 0, 16, 2, 1, 0x11, 0]) + J.sos + J.scan + J.eoi,
             .malformed(offset: at)),
            ("SOS length disagrees with Ns", head + J.sof() + J.seg(0xDA, [2, 1, 0, 0, 63, 0]) + J.scan + J.eoi,
             .malformed(offset: at + J.sof().count)),
            ("DRI of the wrong length", head + J.seg(0xDD, [0, 4, 0]) + J.body, .malformed(offset: at)),
            ("RST outside a scan", head + [0xFF, 0xD0] + J.body, .malformed(offset: at)),
            ("FF 00 outside a scan", head + [0xFF, 0x00] + J.body, .malformed(offset: at)),
        ]
        for (label, bytes, expected) in cases {
            assertThrows(bytes, expected, label)
            XCTAssertTrue(S.check(Data(bytes)).contains { $0.kind == .structure }, "\(label): check has no .structure")
        }
    }

    // T2: the walk ends at EOI. An image appended after it (an MPF preview, say) is rejected
    // whole, never walked into and never trimmed off.
    func testAppendedSecondImageAfterEOIIsRejected() {
        let first = J.jpeg()
        let appended = first + J.jpeg([J.jfif(), J.exif])
        assertThrows(appended, .trailingBytes(offset: first.count), "second image after EOI")
        XCTAssertEqual(found(appended), ["trailingBytes 0 @\(first.count)"])

        for tail: [UInt8] in [[0x00], [0xFF], J.eoi, [0xFF, 0xD8]] {
            assertThrows(first + tail, .trailingBytes(offset: first.count), "tail \(tail)")
            XCTAssertEqual(found(first + tail), ["trailingBytes 0 @\(first.count)"])
        }

        // check reports the segments it saw before EOI as well as the tail.
        let dirty = J.jpeg([J.jfif(), J.exif]) + [0x00]
        XCTAssertEqual(found(dirty), ["segment e1 @\(2 + J.jfif().count)", "trailingBytes 0 @\(dirty.count - 1)"])
    }

    // T2, M12: a second SOI before EOI is a second image. strip throws; it never drops the
    // marker and carries on walking.
    func testSecondSOIInSegmentSpaceIsRejected() {
        let head = J.soi + J.jfif()
        let early = head + J.soi + J.body
        assertThrows(early, .secondImage(offset: head.count), "SOI among the APP segments")
        XCTAssertEqual(found(early), ["secondImage d8 @\(head.count)"])

        // After a scan: FF D8 is not scan data, so it ends the scan and lands in segment space.
        let scanEnd = head + J.dqt + J.sof() + J.dht + J.sos + J.scan
        let late = scanEnd + J.soi + J.dqt + J.sof() + J.dht + J.sos + J.scan + J.eoi
        assertThrows(late, .secondImage(offset: scanEnd.count), "SOI after a scan")
        XCTAssertTrue(S.check(Data(late)).contains { $0.kind == .secondImage && $0.offset == scanEnd.count })

        // Behind a fill byte it is still a second SOI (offset is the FF right before D8).
        let filled = head + [0xFF] + J.soi + J.body
        assertThrows(filled, .secondImage(offset: head.count + 1), "SOI after a fill byte")
    }

    // T5, M12: APP0 is kept only as plain JFIF. JFXX (a thumbnail extension) and anything else
    // in APP0 is dropped by strip and flagged by check.
    func testAPP0WithoutJFIFIdentifierIsDropped() {
        let input = J.jpeg([J.jfif(), J.jfxx, J.fakeJFIF, J.junkAPP0])
        XCTAssertEqual(stripped(input), J.jpeg([J.jfif()]))
        var at = 2 + J.jfif().count
        let jfxxAt = at; at += J.jfxx.count
        let fakeAt = at; at += J.fakeJFIF.count
        XCTAssertEqual(found(input), ["thumbnail e0 @\(jfxxAt)", "segment e0 @\(fakeAt)", "segment e0 @\(at)"])

        // A file whose only APP0 is JFXX keeps no APP0 at all.
        XCTAssertEqual(stripped(J.jpeg([J.jfxx])), J.jpeg([]))
        XCTAssertEqual(found(J.jpeg([J.jfxx])), ["thumbnail e0 @2"])
    }

    // T12, M12: JFIF itself can carry an inline RGB thumbnail. Non-zero sizes, or any byte past
    // the 14-byte payload, and the segment goes.
    func testJFIFWithInlineThumbnailIsDropped() {
        for (label, app0, kind) in [("2x1 thumbnail", J.jfif(thumbW: 2, thumbH: 1), "thumbnail"),
                                    ("width only, no pixels", J.jfif(thumbW: 1, thumbH: 0), "thumbnail"),
                                    ("height only, no pixels", J.jfif(thumbW: 0, thumbH: 1), "thumbnail"),
                                    ("sizes 0 but extra bytes", J.jfif(extra: [0x7F, 0x7F, 0x7F]), "segment")] {
            let input = J.jpeg([app0])
            XCTAssertEqual(stripped(input), J.jpeg([]), label)
            XCTAssertEqual(found(input), ["\(kind) e0 @2"], label)
        }
        // The plain JFIF segment is length 16 and passes.
        XCTAssertEqual(J.jfif().count, 18)
        XCTAssertEqual(found(J.jpeg([J.jfif()])), [])
    }

    // T5: APP2 is kept only with the ICC_PROFILE\0 identifier. MPF (which points at appended
    // images) and FlashPix go.
    func testAPP2WithoutICCIdentifierIsDropped() {
        let input = J.jpeg([J.jfif(), J.icc, J.mpf, J.flashpix, J.iccNoNUL])
        XCTAssertEqual(stripped(input), J.jpeg([J.jfif(), J.icc]))
        var at = 2 + J.jfif().count + J.icc.count
        let mpfAt = at; at += J.mpf.count
        let fpxAt = at; at += J.flashpix.count
        XCTAssertEqual(found(input), ["segment e2 @\(mpfAt)", "segment e2 @\(fpxAt)", "segment e2 @\(at)"])
        XCTAssertEqual(found(J.jpeg([J.jfif(), J.icc])), [], "ICC is allowed")
    }

    // T7: fill bytes (extra FFs before a marker code) advance one byte at a time, in segment
    // space and inside a scan. An odd count is the case a two-byte step gets wrong.
    func testFillBytesBeforeAMarkerAdvanceOneByte() {
        let input = J.soi + J.jfif() + [0xFF] + J.exif + [0xFF, 0xFF, 0xFF] + J.dqt + J.sof() + J.dht + J.sos
            + J.scan + [0xFF] + J.eoi                     // the scan ends FF FF D9
        // Fill bytes in segment space are padding and are not copied. The FF just before EOI
        // belongs to the scan's bytes (the scan ends at the FF that starts a marker).
        let golden = J.soi + J.jfif() + J.dqt + J.sof() + J.dht + J.sos + J.scan + [0xFF] + J.eoi
        XCTAssertEqual(stripped(input), golden)
        XCTAssertEqual(found(input), ["segment e1 @\(2 + J.jfif().count + 1)"], "APP1 found behind one fill byte")
        XCTAssertEqual(found(golden), [])

        // FF FF D9 straight after a scan header's data ends the file cleanly.
        XCTAssertNotNil(stripped(J.soi + J.sof() + J.sos + [0x01, 0xFF, 0xFF, 0xD9]))
        // Three fills inside a scan.
        XCTAssertNotNil(stripped(J.soi + J.sof() + J.sos + [0x01, 0xFF, 0xFF, 0xFF, 0xD9]))
    }

    // T7: in segment space the byte after a segment must be FF. Anything else is not a marker.
    func testNonFFByteWhereAMarkerBelongsThrows() {
        assertThrows(J.soi + [0x00] + J.body, .malformed(offset: 2), "SOI 00 DB")
        assertThrows(J.soi + [0xDB] + J.body, .malformed(offset: 2), "SOI DB, no FF")
        let head = J.soi + J.jfif()
        assertThrows(head + [0x12] + J.body, .malformed(offset: head.count), "stray byte after APP0")
        XCTAssertTrue(S.check(Data(J.soi + [0x00] + J.body)).contains { $0.kind == .structure && $0.offset == 2 })
    }

    // Review finding (multi-scan rejected in an earlier attempt): a progressive file with tables
    // and segments between scans round-trips, minus only the dropped segments.
    func testMultiScanFileRoundTrips() {
        func progressive(_ between: [UInt8]) -> [UInt8] {
            J.soi + J.jfif() + J.dqt + J.dri + J.sof(0xC2) + J.dht + J.sos + J.scan
                + J.dht2 + J.sos + J.scan2 + between + J.sos + J.scan3 + J.eoi
        }
        let input = progressive(J.com + J.exif)
        let golden = progressive([])
        XCTAssertEqual(stripped(input), golden)
        XCTAssertEqual(found(golden), [])
        XCTAssertEqual(found(input).count, 2)
        // Stripping is idempotent: a clean file comes back byte-identical.
        XCTAssertEqual(stripped(golden), golden)
        XCTAssertEqual(stripped(J.jpeg([J.jfif(), J.icc])), J.jpeg([J.jfif(), J.icc]))
    }

    // Rule 14: the marker lists are allowlists. A marker not on them throws; nothing defaults to
    // keep (or to drop).
    func testUnknownMarkersThrowNeverKeep() {
        let head = J.soi + J.jfif()
        // TEM, reserved, JPG, DAC, DNL, DHP, EXP, JPGn.
        let unknown: [UInt8] = [0x01, 0x02, 0x4F, 0xBF, 0xC8, 0xCC, 0xDC, 0xDE, 0xDF, 0xF0, 0xF7, 0xFD]
        for m in unknown {
            let bytes = head + J.seg(m, [0, 0]) + J.body
            assertThrows(bytes, .unsupportedMarker(m, offset: head.count), "marker \(m)")
            XCTAssertTrue(S.check(Data(bytes)).contains { $0.marker == m && $0.offset == head.count }, "check misses \(m)")
            XCTAssertFalse(S.check(Data(bytes)).isEmpty)
        }
        // Between two scans as well.
        let firstScan = head + J.dqt + J.sof(0xC2) + J.dht + J.sos + J.scan
        let between = firstScan + J.seg(0xDC, [0, 1]) + J.sos + J.scan2 + J.eoi
        assertThrows(between, .unsupportedMarker(0xDC, offset: firstScan.count), "DNL between scans")
    }

    // Rule 16: what strip returns passes check, for every fixture strip accepts; and strip
    // really runs check on its own output and throws when it fails.
    func testStripOutputAlwaysPassesCheck() {
        let fixtures: [[UInt8]] = [
            J.jpeg(), J.jpeg([]), J.jpeg([J.jfif(), J.exif, J.xmp]), J.jpeg([J.jfif(), J.app13, J.com]),
            J.jpeg([J.jfif(), J.jfxx, J.fakeJFIF, J.junkAPP0]), J.jpeg([J.jfif(thumbW: 2, thumbH: 1)]),
            J.jpeg([J.jfif(), J.icc, J.mpf, J.flashpix, J.iccNoNUL]),
            J.soi + J.jfif() + [0xFF] + J.exif + [0xFF, 0xFF] + J.body,
            J.soi + J.jfif() + J.dqt + J.dri + J.sof(0xC2) + J.dht + J.sos + J.scan + J.com + J.sos + J.scan2 + J.eoi,
        ] + [UInt8]([0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]).map {
            J.soi + J.dqt + J.sof($0) + J.dht + J.sos + J.scan + J.eoi   // every SOFn on the list
        }
        for (n, bytes) in fixtures.enumerated() {
            guard let out = stripped(bytes) else { continue }
            XCTAssertEqual(S.check(Data(out)), [], "fixture \(n)")
        }

        // The self-check is wired in: hand strip a checker that always objects and it must throw.
        let objector: (Data) -> [S.Violation] = { _ in [S.Violation(kind: .segment, marker: 0xE1, offset: 7)] }
        XCTAssertThrowsError(try S.strip(Data(J.jpeg()), verifiedBy: objector)) { error in
            XCTAssertEqual(error as? S.ScrubError, .malformed(offset: 7))
        }
    }

    // Rule 10: check never says [] for something it could not parse.
    func testCheckOfUnparsableInputIsAViolationNotEmpty() {
        let garbage: [[UInt8]] = [
            [], [0x00], [0xFF], [0xFF, 0xD8], [0xFF, 0xD8, 0xFF, 0xD9],
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],   // a PNG signature
            J.ascii("hello, world"),
            (0..<64).map { UInt8(($0 * 37 + 11) & 0xFF) },
            J.soi + [0xFF, 0xE1, 0xFF, 0xFF],
        ]
        for bytes in garbage {
            let v = S.check(Data(bytes))
            XCTAssertFalse(v.isEmpty, "check said clean for \(bytes.prefix(8))")
            XCTAssertTrue(v.contains { $0.kind == .structure }, "no .structure for \(bytes.prefix(8))")
            XCTAssertThrowsError(try S.strip(Data(bytes)))
        }
        // Descriptions carry kinds, markers and offsets only.
        XCTAssertEqual(S.Violation(kind: .segment, marker: 0xE1, offset: 20).description, "segment marker 0xE1 at offset 20")
        XCTAssertEqual(S.ScrubError.unsupportedMarker(0x01, offset: 4).description, "unsupported marker 0x01 at offset 4")
    }
}
