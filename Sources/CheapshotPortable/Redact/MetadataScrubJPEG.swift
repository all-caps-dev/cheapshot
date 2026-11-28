// Swift. JPEG segment stripper and allowlist checker (CHE-52; redact engine plan, section 3.5
// and fail-closed rules 10 to 16). Foundation only, so it builds on Windows.
//
// Threat model: these bytes come from our own encoder, drawn from a fresh canvas. The job is to
// remove what ImageIO adds (Exif, XMP, MPF, thumbnails) and to refuse anything unexpected. The
// walk understands a short list of markers and throws on everything else; nothing is kept by
// default.
//
// Accepted grammar: SOI, then segments, then exactly one SOF0 (baseline) or SOF2 (progressive),
// the only two frame types ImageIO writes, then one or more SOS each followed by entropy-coded
// data, then EOI, then end of data. Tables (DQT, DHT, DRI) may also sit between scans, as in
// progressive files. Kept tables are parsed table by table, so their payload holds tables only,
// each table id at most once per segment (redefining an id in a later segment stays legal).
// A JFIF APP0 is kept only straight after SOI, and an ICC APP2 only before the frame header.
import Foundation

public enum MetadataScrubJPEG {
    public enum ScrubError: Error, Equatable, CustomStringConvertible {
        case notJPEG, missingEOI, missingFrame
        case truncated(offset: Int), malformed(offset: Int)
        case secondImage(offset: Int), trailingBytes(offset: Int)
        case unsupportedMarker(UInt8, offset: Int)

        // Kinds, markers and offsets only: never a byte of segment content (plan rule 30).
        public var description: String {
            switch self {
            case .notJPEG: return "not a JPEG (no SOI at offset 0)"
            case .missingEOI: return "no EOI before the end of the data"
            case .missingFrame: return "no frame header (SOFn) before the scan or EOI"
            case .truncated(let o): return "truncated at offset \(o)"
            case .malformed(let o): return "malformed at offset \(o)"
            case .secondImage(let o): return "second SOI at offset \(o)"
            case .trailingBytes(let o): return "bytes after EOI at offset \(o)"
            case .unsupportedMarker(let m, let o): return "unsupported marker \(hex(m)) at offset \(o)"
            }
        }
    }

    /// One thing `check` objects to. `offset` is where the marker's FF sits in the input.
    public struct Violation: Equatable, CustomStringConvertible {
        public enum Kind: String { case structure, segment, secondImage, trailingBytes, thumbnail }
        public let kind: Kind; public let marker: UInt8; public let offset: Int
        public var description: String { "\(kind.rawValue) marker \(hex(marker)) at offset \(offset)" }
    }

    /// Removes what ImageIO adds. Throws on anything it does not fully understand; never returns
    /// its input for bad data. The bytes it returns always pass `check` (rule 16).
    public static func strip(_ data: Data) throws -> Data {
        try strip(data, verifiedBy: check)
    }

    /// The real strip. `verify` is `check` in production; tests pass a checker that always objects,
    /// to prove the self-check below is wired in and makes strip throw.
    static func strip(_ data: Data, verifiedBy verify: (Data) -> [Violation]) throws -> Data {
        let bytes = [UInt8](data)   // copy into an array so offsets start at 0 even for a Data slice
        var pieces: [Piece] = []
        try walk(bytes, into: &pieces)

        // A fresh buffer built only from the kept pieces. Fill bytes between segments are not in
        // any piece, so they are not copied either.
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for piece in pieces where piece.dropped == nil {
            out.append(contentsOf: bytes[piece.range])
        }
        let result = Data(out)

        // Rule 16: our own output must pass the allowlist, or nothing is returned.
        if let first = verify(result).first {
            throw ScrubError.malformed(offset: first.offset)
        }
        return result
    }

    /// Empty means allowlist-clean. Input that will not parse always gives at least one
    /// violation (`.structure` for broken structure), never [].
    public static func check(_ data: Data) -> [Violation] {
        let bytes = [UInt8](data)
        var pieces: [Piece] = []
        var failure: ScrubError?
        do { try walk(bytes, into: &pieces) } catch let error as ScrubError {
            failure = error
        } catch {
            failure = .malformed(offset: 0)   // walk only throws ScrubError; this keeps check total
        }

        // Everything strip would drop is a violation, including what was seen before a failure.
        var found = pieces.compactMap { piece -> Violation? in
            guard let kind = piece.dropped else { return nil }
            return Violation(kind: kind, marker: piece.marker, offset: piece.range.lowerBound)
        }
        if let failure { found.append(violation(for: failure, count: bytes.count)) }
        return found
    }

    // MARK: - The walk

    /// One stretch of the input the walk understood. `dropped` is nil for a kept piece, or the
    /// reason it goes. A SOS piece runs from its FF to the end of the scan's entropy data.
    struct Piece {
        let range: Range<Int>
        let marker: UInt8
        let dropped: Violation.Kind?
    }

    /// Walks the whole input, appending each piece as it is understood, and throws at the first
    /// thing outside the grammar. `pieces` is inout so `check` keeps what came before a throw.
    static func walk(_ b: [UInt8], into pieces: inout [Piece]) throws {
        guard b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 else { throw ScrubError.notJPEG }
        pieces.append(Piece(range: 0..<2, marker: 0xD8, dropped: nil))

        var i = 2            // the next byte to read; always a marker boundary at the loop top
        var frames = 0       // SOFn segments seen; exactly one is allowed
        var scans = 0        // SOS segments seen; at least one before EOI

        while true {
            // A marker belongs here. Running out of data between segments means no EOI.
            guard i < b.count else { throw ScrubError.missingEOI }
            guard b[i] == 0xFF else { throw ScrubError.malformed(offset: i) }   // a non-FF byte is not a marker

            // Fill bytes: any number of extra FFs may come before the marker code. Step over them
            // one byte at a time (a two-byte step lands on the wrong byte after an odd count).
            var m = i + 1
            while m < b.count && b[m] == 0xFF { m += 1 }
            guard m < b.count else { throw ScrubError.truncated(offset: i) }
            let marker = b[m]
            let at = m - 1   // the FF right before the marker code; reported offsets point here

            // Fill bytes between segments are a dropped piece: strip does not copy them, and
            // check reports them, so a clean check means strip would change nothing.
            if at > i { pieces.append(Piece(range: i..<at, marker: 0xFF, dropped: .structure)) }

            // Markers with no length field.
            switch marker {
            case 0xD9:   // EOI: the walk ends here, and so must the data.
                guard frames == 1 else { throw ScrubError.missingFrame }
                guard scans >= 1 else { throw ScrubError.malformed(offset: at) }
                pieces.append(Piece(range: at..<(m + 1), marker: marker, dropped: nil))
                let end = m + 1
                guard end == b.count else { throw ScrubError.trailingBytes(offset: end) }
                return
            case 0xD8:   // a second SOI: a second image. Rejected, never skipped.
                throw ScrubError.secondImage(offset: at)
            case 0xD0...0xD7, 0x00:   // RSTn and stuffed zero are scan data, never segment markers
                throw ScrubError.malformed(offset: at)
            default:
                break
            }

            // Only markers on the allowlist get as far as reading a length (rule 14).
            guard isKnownSegment(marker) else { throw ScrubError.unsupportedMarker(marker, offset: at) }

            // Length: two big-endian bytes that count themselves. Bounds-checked before any use
            // (rule 13): under 2 is malformed, past the end is truncated.
            guard m + 3 <= b.count else { throw ScrubError.truncated(offset: at) }
            let length = Int(b[m + 1]) << 8 | Int(b[m + 2])
            guard length >= 2 else { throw ScrubError.malformed(offset: at) }
            let end = m + 1 + length   // one past the segment's last byte
            guard end <= b.count else { throw ScrubError.truncated(offset: at) }
            let payload = b[(m + 3)..<end]   // after the length field

            switch marker {
            case 0xE0:   // APP0: kept only as plain JFIF with no thumbnail, straight after SOI
                var verdict = app0Verdict(payload)
                if verdict == nil && at != 2 { verdict = .segment }   // a later or second JFIF
                pieces.append(Piece(range: at..<end, marker: marker, dropped: verdict))
            case 0xE2:   // APP2: kept only as an ICC profile chunk, before the frame header
                let keep = isICCChunk(payload) && frames == 0
                pieces.append(Piece(range: at..<end, marker: marker, dropped: keep ? nil : .segment))
            case 0xE1, 0xE3...0xEF, 0xFE:   // APP1 (Exif, XMP), APP3 to APP15, COM: always dropped
                pieces.append(Piece(range: at..<end, marker: marker, dropped: .segment))
            case 0xDB:   // DQT: quantization tables, kept once every byte is accounted for
                guard isValidDQT(payload) else { throw ScrubError.malformed(offset: at) }
                pieces.append(Piece(range: at..<end, marker: marker, dropped: nil))
            case 0xC4:   // DHT: Huffman tables, the same
                guard isValidDHT(payload) else { throw ScrubError.malformed(offset: at) }
                pieces.append(Piece(range: at..<end, marker: marker, dropped: nil))
            case 0xDD:   // DRI: restart interval, always a 2-byte payload
                guard length == 4 else { throw ScrubError.malformed(offset: at) }
                pieces.append(Piece(range: at..<end, marker: marker, dropped: nil))
            case 0xDA:   // SOS: scan header, then entropy data up to the next real marker
                guard frames == 1 else { throw ScrubError.missingFrame }
                // Ns components, 1 to 4; the header is 6 + 2 * Ns bytes long.
                let ns = Int(payload.first ?? 0)
                guard (1...4).contains(ns), length == 6 + 2 * ns else { throw ScrubError.malformed(offset: at) }
                let scanEnd = try endOfScan(b, from: end)
                scans += 1
                pieces.append(Piece(range: at..<scanEnd, marker: marker, dropped: nil))
                i = scanEnd
                continue
            default:   // what is left of isKnownSegment: the frame headers SOF0 and SOF2
                frames += 1
                guard frames == 1 else { throw ScrubError.malformed(offset: at) }   // two frames
                // Nf components, at least 1; the header is 8 + 3 * Nf bytes long.
                let nf = payload.count >= 6 ? Int(payload[payload.startIndex + 5]) : 0
                guard nf >= 1, length == 8 + 3 * nf else { throw ScrubError.malformed(offset: at) }
                pieces.append(Piece(range: at..<end, marker: marker, dropped: nil))
            }
            i = end
        }
    }

    /// Finds where a scan's entropy data ends: the offset of the FF that starts the next real
    /// marker. Inside a scan, FF 00 (a stuffed zero) and FF D0 to FF D7 (restart markers) are
    /// data; FF FF is a fill byte and advances one; any other FF xx ends the scan. Running out of
    /// data first means the file has no EOI.
    static func endOfScan(_ b: [UInt8], from start: Int) throws -> Int {
        var j = start
        while true {
            guard j < b.count else { throw ScrubError.missingEOI }
            if b[j] != 0xFF { j += 1; continue }
            guard j + 1 < b.count else { throw ScrubError.missingEOI }
            let next = b[j + 1]
            if next == 0x00 || (0xD0...0xD7).contains(next) {
                j += 2           // data
            } else if next == 0xFF {
                j += 1           // fill byte: one at a time
            } else {
                return j         // a marker: the scan ends at its FF
            }
        }
    }

    // MARK: - Allowlists

    /// Markers whose segment the walk knows how to read. Everything else, including TEM, DAC,
    /// JPG, DNL, DHP, EXP, JPGn, reserved codes and every frame type other than SOF0 and SOF2
    /// (ImageIO writes only those two), is `unsupportedMarker`.
    static func isKnownSegment(_ m: UInt8) -> Bool {
        switch m {
        case 0xE0...0xEF, 0xFE: return true          // APPn, COM (read so they can be judged)
        case 0xDB, 0xC4, 0xDD, 0xDA: return true     // DQT, DHT, DRI, SOS
        case 0xC0, 0xC2: return true                 // SOF0 baseline, SOF2 progressive
        default: return false
        }
    }

    /// DQT payload: one or more tables, each a byte Pq<<4 | Tq (Pq 0 or 1, Tq 0 to 3) then 64
    /// one-byte values (Pq 0) or 64 two-byte values (Pq 1). The tables must use up the payload
    /// exactly, and each Tq may appear once, so one segment holds at most 4 tables. The limit is
    /// per segment: a later DQT may redefine a table. The table values themselves are free bytes,
    /// so this bounds what a segment can carry; it does not make it zero.
    static func isValidDQT(_ p: ArraySlice<UInt8>) -> Bool {
        guard !p.isEmpty else { return false }
        var seen: UInt8 = 0   // bit n set once table id n has appeared in this segment
        var k = p.startIndex
        while k < p.endIndex {
            let pq = p[k] >> 4, tq = p[k] & 0x0F
            guard pq <= 1, tq <= 3, seen & (1 << tq) == 0 else { return false }
            seen |= 1 << tq
            let size = pq == 0 ? 64 : 128
            k += 1
            guard p.endIndex - k >= size else { return false }   // table cut short
            k += size
        }
        return true   // the loop only ends with k exactly at the end
    }

    /// DHT payload: one or more tables, each a byte Tc<<4 | Th (Tc 0 or 1, Th 0 to 3), 16 code
    /// counts, then exactly as many symbols as the counts add up to (at most 256, one per byte
    /// value). The tables must use up the payload exactly, and each (Tc, Th) pair may appear once,
    /// so one segment holds at most 8 tables. The limit is per segment: progressive files
    /// redefine tables between scans in later DHT segments, which stays legal.
    static func isValidDHT(_ p: ArraySlice<UInt8>) -> Bool {
        guard !p.isEmpty else { return false }
        var seen: UInt8 = 0   // bit Tc * 4 + Th set once that pair has appeared in this segment
        var k = p.startIndex
        while k < p.endIndex {
            let tc = p[k] >> 4, th = p[k] & 0x0F
            guard tc <= 1, th <= 3 else { return false }
            let bit: UInt8 = 1 << (tc * 4 + th)
            guard seen & bit == 0 else { return false }
            seen |= bit
            k += 1
            guard p.endIndex - k >= 16 else { return false }     // counts cut short
            let symbols = p[k..<(k + 16)].reduce(0) { $0 + Int($1) }
            k += 16
            guard symbols <= 256, p.endIndex - k >= symbols else { return false }
            k += symbols
        }
        return true
    }

    /// An ICC APP2 chunk: "ICC_PROFILE\0", then a sequence number and a chunk count, with
    /// 1 <= sequence <= count. Just the identifier, or a bad pair, is not one.
    static func isICCChunk(_ p: ArraySlice<UInt8>) -> Bool {
        guard p.starts(with: iccIdentifier), p.count >= iccIdentifier.count + 2 else { return false }
        let sequence = p[p.startIndex + iccIdentifier.count]
        let count = p[p.startIndex + iccIdentifier.count + 1]
        return sequence >= 1 && sequence <= count
    }

    static let jfifIdentifier: [UInt8] = Array("JFIF".utf8) + [0]
    static let jfxxIdentifier: [UInt8] = Array("JFXX".utf8) + [0]
    static let iccIdentifier: [UInt8] = Array("ICC_PROFILE".utf8) + [0]

    /// nil (keep) only for "JFIF\0" plus exactly 9 bytes whose last two (the thumbnail width and
    /// height) are both 0: a segment of length 16. Otherwise the reason it is dropped.
    static func app0Verdict(_ p: ArraySlice<UInt8>) -> Violation.Kind? {
        if p.starts(with: jfxxIdentifier) { return .thumbnail }   // JFIF extension: a thumbnail
        guard p.starts(with: jfifIdentifier), p.count >= 14 else { return .segment }
        let thumbW = p[p.startIndex + 12], thumbH = p[p.startIndex + 13]
        if thumbW != 0 || thumbH != 0 { return .thumbnail }
        return p.count == 14 ? nil : .segment   // anything after the 14 bytes is not plain JFIF
    }

    /// The violation `check` reports when the walk stops on an error.
    static func violation(for error: ScrubError, count: Int) -> Violation {
        switch error {
        case .secondImage(let o): return Violation(kind: .secondImage, marker: 0xD8, offset: o)
        case .trailingBytes(let o): return Violation(kind: .trailingBytes, marker: 0, offset: o)
        case .unsupportedMarker(let m, let o): return Violation(kind: .segment, marker: m, offset: o)
        case .notJPEG: return Violation(kind: .structure, marker: 0, offset: 0)
        case .missingEOI: return Violation(kind: .structure, marker: 0xD9, offset: count)
        case .missingFrame: return Violation(kind: .structure, marker: 0xC0, offset: 0)
        case .truncated(let o), .malformed(let o): return Violation(kind: .structure, marker: 0, offset: o)
        }
    }
}

/// "0xE1": a marker code as two uppercase hex digits. Avoids String(format:) to stay plain Swift.
private func hex(_ m: UInt8) -> String {
    let digits = String(m, radix: 16, uppercase: true)
    return "0x" + (digits.count == 1 ? "0" + digits : digits)
}
