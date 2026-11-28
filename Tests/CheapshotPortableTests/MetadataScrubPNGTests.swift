import XCTest
@testable import CheapshotPortable

// Swift (XCTest). Tests for MetadataScrubPNG (CHE-53, plan P3). Fixtures are built by hand in
// this file: no ImageIO, so they run on Windows and on the iOS Simulator too.
final class MetadataScrubPNGTests: XCTestCase {

    // MARK: fixtures

    /// Turns "89504e47..." into bytes. Used for the golden fixtures below, whose CRCs were made
    /// with zlib (Python), so they do not depend on the crc32 under test.
    private func hex(_ s: String) -> Data {
        var out = Data()
        var it = s.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            out.append(UInt8(String([hi, lo]), radix: 16)!)
        }
        return out
    }

    private let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// One chunk: [4-byte big-endian length][4-byte type][data][4-byte CRC over type + data].
    /// `length` overrides the length field (to lie about it); `crc` overrides the CRC.
    private func chunk(_ type: String, _ data: [UInt8] = [], length: UInt32? = nil, crc: UInt32? = nil) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let n = length ?? UInt32(data.count)
        let sum = crc ?? MetadataScrubPNG.crc32(ArraySlice(typeBytes + data))
        return be32(n) + typeBytes + data + be32(sum)
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    // A 1 x 1 RGBA IHDR payload (13 bytes) and a tiny IDAT payload (never decoded here).
    private let ihdrData: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]
    private let idatData: [UInt8] = [0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]

    private var ihdr: [UInt8] { chunk("IHDR", ihdrData) }
    private var idat: [UInt8] { chunk("IDAT", idatData) }
    private var iend: [UInt8] { chunk("IEND") }

    /// Signature plus the given chunk bytes, as Data.
    private func png(_ parts: [UInt8]...) -> Data { Data(signature + parts.flatMap { $0 }) }

    /// The smallest valid file: IHDR, IDAT, IEND.
    private var minimal: Data { png(ihdr, idat, iend) }

    // Golden input: IHDR sRGB tEXt pHYs eXIf iDOT IDAT zTXt iTXt tIME IEND, CRCs from zlib.
    private lazy var goldenInput = hex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489000000017352474200aece1ce9"
        + "0000001474455874436f6d6d656e74007365637265742d746f6b656effbb48a50000000970485973000016250000"
        + "162501495224f00000000b655849664d4d002a00000008475053a9d937590000001c69444f540001020304050607"
        + "08090a0b0c0d0e0f101112131415161718191a1b156e76640000000a49444154789c636000000002000148afa471"
        + "000000167a545874417574686f720000789c2b4e4d2e4a2d0100089b028aec91bb700000002269545874584d4c3a"
        + "636f6d2e61646f62652e786d7000000000003c783a786d706d6574612f3e18d267b10000000774494d4507ea0b1c"
        + "051500276a6f8d0000000049454e44ae426082")
    // What Masker.dropMetadataChunks returns for goldenInput (checked once against a verbatim copy
    // of that function): IHDR sRGB pHYs iDOT IDAT IEND.
    private lazy var goldenOutput = hex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489000000017352474200aece1ce9"
        + "0000000970485973000016250000162501495224f00000001c69444f54000102030405060708090a0b0c0d0e0f10"
        + "1112131415161718191a1b156e76640000000a49444154789c636000000002000148afa4710000000049454e44ae"
        + "426082")

    /// Asserts `strip` throws exactly `expected`.
    private func assertStripThrows(_ data: Data, _ expected: MetadataScrubPNG.ScrubError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MetadataScrubPNG.strip(data), file: file, line: line) { error in
            XCTAssertEqual(error as? MetadataScrubPNG.ScrubError, expected, file: file, line: line)
        }
    }

    /// The (kind, chunk) pairs `check` reports, offsets left out for readability.
    private func kinds(_ data: Data) -> [String] {
        MetadataScrubPNG.check(data).map { "\($0.kind):\($0.chunk)" }
    }

    // MARK: tests

    func testDropsTheFiveMetadataChunksLikeMaskerDid() throws {
        let out = try MetadataScrubPNG.strip(goldenInput)
        XCTAssertEqual(out, goldenOutput, "byte-golden: same bytes Masker.dropMetadataChunks returns")
        XCTAssertNotEqual(out, goldenInput, "strip never hands back its input when it removed something")
        XCTAssertEqual(MetadataScrubPNG.check(out), [])
        // The unstripped file is flagged once per metadata chunk, at the chunk's offset.
        XCTAssertEqual(kinds(goldenInput), ["notAllowed:tEXt", "notAllowed:eXIf", "notAllowed:zTXt",
                                            "notAllowed:iTXt", "notAllowed:tIME"])
        XCTAssertEqual(MetadataScrubPNG.check(goldenInput).first?.offset, 8 + 25 + 13)
        // A clean file comes back unchanged.
        XCTAssertEqual(try MetadataScrubPNG.strip(goldenOutput), goldenOutput)
    }

    func testUnknownAncillaryChunkIsDroppedUnknownCriticalThrows() throws {
        // cICP is ancillary (lowercase first letter) and not on the list: dropped, and flagged by check.
        let withCICP = png(ihdr, chunk("cICP", [1, 13, 0, 1]), idat, iend)
        XCTAssertEqual(try MetadataScrubPNG.strip(withCICP), minimal)
        XCTAssertEqual(kinds(withCICP), ["notAllowed:cICP"])

        // XYZa is critical (uppercase first letter) and unknown: never kept, never silently dropped.
        let offset = 8 + 25
        let withXYZa = png(ihdr, chunk("XYZa", [9, 9]), idat, iend)
        assertStripThrows(withXYZa, .unknownCriticalChunk("XYZa", offset: offset))
        XCTAssertEqual(MetadataScrubPNG.check(withXYZa),
                       [MetadataScrubPNG.Violation(kind: "notAllowed", chunk: "XYZa", offset: offset)])

        // A type that is not four ASCII letters is not a chunk at all.
        let junkType = png(ihdr, chunk("ab1c", [0]), idat, iend)
        XCTAssertThrowsError(try MetadataScrubPNG.strip(junkType))
        XCTAssertEqual(kinds(junkType).first?.hasPrefix("structure:"), true)
    }

    func testBadCRCThrows() {
        // One flipped bit in the IDAT payload; its CRC no longer matches.
        var bytes = [UInt8](minimal)
        let idatOffset = 8 + 25
        bytes[idatOffset + 8] ^= 0x01
        let flipped = Data(bytes)
        assertStripThrows(flipped, .badCRC(chunk: "IDAT", offset: idatOffset))
        XCTAssertEqual(MetadataScrubPNG.check(flipped),
                       [MetadataScrubPNG.Violation(kind: "badCRC", chunk: "IDAT", offset: idatOffset)])

        // A chunk that strip would drop anyway still has its CRC checked.
        let badText = png(ihdr, chunk("tEXt", Array("a\u{0}b".utf8), crc: 0), idat, iend)
        assertStripThrows(badText, .badCRC(chunk: "tEXt", offset: 8 + 25))

        // So does IEND, the last chunk.
        let badIEND = png(ihdr, idat, chunk("IEND", crc: 0xAE42_6083))
        assertStripThrows(badIEND, .badCRC(chunk: "IEND", offset: 8 + 25 + 22))
    }

    func testChunkAfterIENDIsRejected() {
        let afterIEND = 8 + 25 + 22 + 12
        // A whole, valid IDAT appended after IEND: the walk stops at IEND and rejects the rest.
        let idatAfter = png(ihdr, idat, iend, idat)
        assertStripThrows(idatAfter, .trailingBytes(offset: afterIEND))
        XCTAssertEqual(MetadataScrubPNG.check(idatAfter),
                       [MetadataScrubPNG.Violation(kind: "trailingBytes", chunk: "IEND", offset: afterIEND)])

        // A metadata chunk after IEND is rejected too, never dropped and trimmed.
        let textAfter = png(ihdr, idat, iend, chunk("tEXt", Array("k\u{0}secret".utf8)))
        assertStripThrows(textAfter, .trailingBytes(offset: afterIEND))

        // Raw bytes after IEND, even one.
        assertStripThrows(png(ihdr, idat, iend, [0x00]), .trailingBytes(offset: afterIEND))
        assertStripThrows(png(ihdr, idat, iend, Array("secret".utf8)), .trailingBytes(offset: afterIEND))
        XCTAssertEqual(kinds(png(ihdr, idat, iend, [0x00])), ["trailingBytes:IEND"])

        // A second whole PNG appended after the first.
        let twice = Data([UInt8](minimal) + [UInt8](minimal))
        assertStripThrows(twice, .trailingBytes(offset: afterIEND))
    }

    func testChunkLengthPastEndThrows() {
        let idatOffset = 8 + 25
        // IDAT, the last chunk, claims one byte more than the file holds.
        let longIDAT = png(ihdr, chunk("IDAT", idatData, length: UInt32(idatData.count + 1)))
        assertStripThrows(longIDAT, .truncated(offset: idatOffset))
        XCTAssertEqual(kinds(longIDAT), ["truncated:"])

        // A huge length (the largest the field holds) is bounds-checked, not trusted: no trap,
        // and nothing after it is skipped unchecked.
        let huge = png(ihdr, chunk("tEXt", [0x61], length: 0xFFFF_FFFF), idat, iend)
        assertStripThrows(huge, .truncated(offset: idatOffset))
        XCTAssertFalse(MetadataScrubPNG.check(huge).isEmpty)

        // A length that lands inside the file but on the wrong boundary: the CRC read there is
        // not the chunk's CRC, so it fails instead of skipping ahead.
        let swallow = png(ihdr, chunk("tEXt", [0x61], length: 1 + 12), idat, iend)
        XCTAssertThrowsError(try MetadataScrubPNG.strip(swallow))
        XCTAssertFalse(MetadataScrubPNG.check(swallow).isEmpty)

        // Cut mid-chunk and cut inside a chunk header.
        let full = [UInt8](minimal)
        assertStripThrows(Data(full[0..<(idatOffset + 15)]), .truncated(offset: idatOffset))
        assertStripThrows(Data(full[0..<(idatOffset + 5)]), .truncated(offset: idatOffset))
    }

    func testSignatureOnlyAndMissingIHDROrIDATAreViolations() {
        // Signature only: no IHDR, no IDAT, no IEND. Never clean.
        let sigOnly = Data(signature)
        XCTAssertFalse(MetadataScrubPNG.check(sigOnly).isEmpty)
        XCTAssertEqual(kinds(sigOnly), ["structure:IHDR"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(sigOnly))

        // No IHDR: IDAT comes first.
        let noIHDR = png(idat, iend)
        XCTAssertEqual(kinds(noIHDR), ["structure:IHDR"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(noIHDR))

        // No IHDR, and the first chunk is an allowed one that happens to be 13 bytes long.
        let allowedFirst = png(chunk("sRGB", Array(repeating: 0, count: 13)), idat, iend)
        XCTAssertEqual(kinds(allowedFirst), ["structure:IHDR"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(allowedFirst))

        // No IDAT.
        let noIDAT = png(ihdr, iend)
        XCTAssertEqual(kinds(noIDAT), ["structure:IDAT"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(noIDAT))

        // No IEND: the data simply ends after IDAT.
        let noIEND = png(ihdr, idat)
        XCTAssertEqual(kinds(noIEND), ["structure:IEND"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(noIEND))

        // Only metadata chunks around an IHDR.
        let onlyMeta = png(ihdr, chunk("tEXt", Array("a\u{0}b".utf8)), iend)
        XCTAssertTrue(kinds(onlyMeta).contains("structure:IDAT"))
    }

    func testIHDRFirstWithLength13AndEmptyIEND() {
        // IHDR with 12 bytes of data instead of 13.
        let shortIHDR = png(chunk("IHDR", Array(ihdrData.dropLast())), idat, iend)
        XCTAssertEqual(kinds(shortIHDR), ["structure:IHDR"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(shortIHDR))

        // A second IHDR later in the file.
        let twoIHDR = png(ihdr, idat, ihdr, iend)
        XCTAssertEqual(kinds(twoIHDR), ["structure:IHDR"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(twoIHDR))

        // IEND that carries data, even with a correct CRC over it.
        let fatIEND = png(ihdr, idat, chunk("IEND", Array("secret".utf8)))
        XCTAssertEqual(kinds(fatIEND), ["structure:IEND"])
        XCTAssertThrowsError(try MetadataScrubPNG.strip(fatIEND))
    }

    func testNotPNGOrGarbageThrowsAndIsNeverClean() {
        for bad in [Data(), Data([0x89, 0x50, 0x4E]), Data("GIF89a not a png at all".utf8),
                    Data(signature.dropLast() + [0x0B]) + Data(ihdr + idat + iend)] {
            assertStripThrows(bad, .notPNG)
            XCTAssertEqual(kinds(bad), ["notPNG:"], "check is never [] for input it cannot parse")
        }
    }

    func testStripOutputAlwaysPassesCheck() throws {
        // Every well-formed fixture in this file: strip succeeds and its output is clean.
        let fixtures: [Data] = [
            goldenInput, goldenOutput, minimal,
            png(ihdr, chunk("cICP", [1, 13, 0, 1]), idat, iend),
            png(ihdr, chunk("PLTE", [0, 0, 0]), chunk("tRNS", [0]), idat, idat, chunk("tEXt", [0x61, 0]), iend),
            png(ihdr, chunk("gAMA", [0, 0, 0xB1, 0x8F]), chunk("iCCP", Array("sRGB\u{0}\u{0}x".utf8)),
                chunk("cHRM", Array(repeating: 1, count: 32)), chunk("sBIT", [8, 8, 8, 8]), idat, iend),
        ]
        for f in fixtures {
            let out = try MetadataScrubPNG.strip(f)
            XCTAssertEqual(MetadataScrubPNG.check(out), [])
            XCTAssertEqual(try MetadataScrubPNG.strip(out), out, "strip is idempotent")
        }

        // strip checks its own output before returning it (rule 16): a strip that would keep a
        // chunk outside the allowlist throws instead of returning those bytes.
        XCTAssertThrowsError(try MetadataScrubPNG.strip(goldenInput, keeping: { _ in true })) { error in
            guard case .structure? = error as? MetadataScrubPNG.ScrubError else {
                return XCTFail("want .structure from the output check, got \(error)")
            }
        }
    }

    func testCRC32KnownVectors() {
        XCTAssertEqual(MetadataScrubPNG.crc32(ArraySlice(Array("IEND".utf8))), 0xAE42_6082)
        XCTAssertEqual(MetadataScrubPNG.crc32(ArraySlice(Array("123456789".utf8))), 0xCBF4_3926)
        XCTAssertEqual(MetadataScrubPNG.crc32([]), 0)
        // A slice that does not start at index 0 gives the same answer as a fresh array.
        let padded = Array("xxIENDyy".utf8)
        XCTAssertEqual(MetadataScrubPNG.crc32(padded[2..<6]), 0xAE42_6082)
    }
}
