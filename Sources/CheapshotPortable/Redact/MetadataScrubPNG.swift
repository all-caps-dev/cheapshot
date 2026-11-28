import Foundation

// Swift. PNG chunk dropper and allowlist checker (CHE-53; plan section 3.6, rules 10 to 16).
//
// A PNG file is an 8-byte signature followed by chunks. Each chunk is:
//   [4-byte big-endian length][4-byte type, ASCII letters][length bytes of data][4-byte CRC]
// The CRC covers the type and the data, never the length. A chunk whose type starts with a
// lowercase letter is "ancillary" (a decoder may ignore it); an uppercase first letter means
// "critical" (a decoder must understand it). The file ends with an empty IEND chunk.
//
// Threat model: this only ever sees bytes our own encoder just made from a redrawn canvas. Its
// job is to remove what ImageIO adds (text, EXIF, time) and to refuse anything it does not fully
// understand. Foundation only, so it builds on Windows; that is why CRC-32 is written out here
// instead of coming from zlib.
//
// What is kept: IHDR (every field checked), sRGB (one byte, checked), IEND (empty), and the
// picture itself: IDAT, plus PLTE for a palette image. Each kept chunk appears where and as often
// as the PNG spec allows. No kept chunk outside the picture data has a free byte. Known limit: IDAT holds a zlib stream, and bytes after the end of that stream inside an
// IDAT cannot be found without inflating it, which this parser does not do. The encoder writes
// those IDATs itself from a redrawn canvas, and Verify decodes the result.
public enum MetadataScrubPNG {

    public enum ScrubError: Error, Equatable, CustomStringConvertible {
        case notPNG
        case truncated(offset: Int)
        case badCRC(chunk: String, offset: Int)
        case trailingBytes(offset: Int)
        case structure(String)
        case unknownCriticalChunk(String, offset: Int)

        public var description: String {
            switch self {
            case .notPNG: return "not a PNG (bad signature)"
            case .truncated(let offset): return "PNG chunk at byte \(offset) runs past the end of the data"
            case .badCRC(let chunk, let offset): return "PNG chunk \(chunk) at byte \(offset) has a bad CRC"
            case .trailingBytes(let offset): return "PNG has bytes after IEND, from byte \(offset)"
            case .structure(let why): return "PNG structure: \(why)"
            case .unknownCriticalChunk(let chunk, let offset):
                return "PNG has an unknown critical chunk \(chunk) at byte \(offset)"
            }
        }
    }

    /// One reason a PNG is not allowlist-clean. `kind` is one of: notAllowed, badCRC, truncated,
    /// trailingBytes, structure, notPNG. `chunk` is a chunk type (empty when there is none to
    /// name). Never holds chunk data.
    public struct Violation: Equatable, CustomStringConvertible {
        public let kind: String
        public let chunk: String
        public let offset: Int

        public var description: String {
            chunk.isEmpty ? "\(kind) at byte \(offset)" : "\(kind) \(chunk) at byte \(offset)"
        }
    }

    /// The only chunks an output may hold: the four critical chunks (PLTE for palette images only)
    /// and sRGB. That is ImageIO's own PNG output (IHDR sRGB eXIf IDAT IEND, measured on macOS
    /// 27.2) minus eXIf. Everything else is removed or refused.
    ///
    /// Left out on purpose (CHE-53 reviews, a narrowing of plan 3.6):
    /// - gAMA, cHRM, pHYs, sBIT: their value bytes are free (any gamma, any chromaticity, any
    ///   density), and next to sRGB they change nothing. Dropped like any other ancillary chunk.
    /// - iCCP: a free-text name plus compressed data this parser cannot inflate. The encoder draws
    ///   into sRGB, so ImageIO writes sRGB, not iCCP (measured on macOS 27.2: IHDR sRGB eXIf IDAT
    ///   IEND). Refused, see `refused`.
    /// - iDOT: Apple's decode hint. It holds byte offsets into the file, which go stale once
    ///   chunks are dropped, and it can make Apple's decoder show a different picture from every
    ///   other decoder. Dropped like any other ancillary chunk.
    public static let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB"]

    /// Ancillary chunks that are never kept and never dropped: `strip` throws on them. iCCP cannot
    /// be checked (see `allowed`). tRNS (transparency), the APNG chunks acTL, fcTL, fdAT
    /// (animation frames) and the colour-space chunks cICP, mDCV, cLLI change the picture or how
    /// it renders when removed, so dropping them would quietly write a different image.
    static let refused: Set<String> = ["iCCP", "tRNS", "acTL", "fcTL", "fdAT", "cICP", "mDCV", "cLLI"]

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The PNG spec caps a chunk length at 2^31 - 1.
    static let maxChunkLength = 0x7FFF_FFFF

    /// Removes every chunk outside `allowed`. Throws on anything it does not fully understand
    /// (bad signature, bad CRC, truncation, bytes after IEND, a malformed or misplaced allowlisted
    /// chunk, an unknown critical chunk, a chunk in `refused`), so it never returns its input for
    /// bad data. The bytes it returns always pass `check`.
    public static func strip(_ data: Data) throws -> Data {
        try strip(data, keeping: { allowed.contains($0) })
    }

    /// `strip` with the keep rule passed in. Only tests call this directly, to prove that the
    /// output check below runs (rule 16): a keep rule that lets metadata through must throw.
    static func strip(_ data: Data, keeping keep: (String) -> Bool) throws -> Data {
        let bytes = [UInt8](data)
        let chunks: [Chunk]
        do {
            chunks = try walk(bytes)
        } catch let failure as WalkFailure {
            throw failure.error
        }

        var out = signature
        for c in chunks {
            if keep(c.type) {
                out.append(contentsOf: bytes[c.start..<c.end])   // whole chunk: length, type, data, CRC
            } else if refused.contains(c.type) {
                throw ScrubError.structure("\(c.type) at byte \(c.start) cannot be kept or dropped safely")
            } else if c.isCritical {
                // Critical chunks we do not know cannot be dropped safely and are never kept.
                throw ScrubError.unknownCriticalChunk(c.type, offset: c.start)
            }
            // Otherwise an ancillary chunk outside the allowlist: dropped. Each chunk's CRC covers
            // only itself, so dropping whole chunks leaves every other CRC valid.
        }

        // Rule 16: never return bytes that fail our own check.
        let result = Data(out)
        let problems = check(result)
        guard problems.isEmpty else {
            throw ScrubError.structure("stripped output failed check: "
                                       + problems.map(\.description).joined(separator: ", "))
        }
        return result
    }

    /// Empty means allowlist-clean. Flags every chunk outside `allowed`. Input that will not
    /// walk (bad signature, bad CRC, truncation, missing IHDR, IDAT or IEND, bytes after IEND, an
    /// allowlisted chunk with the wrong length, values, count or place) is one violation naming
    /// the first problem, never [].
    public static func check(_ data: Data) -> [Violation] {
        let chunks: [Chunk]
        do {
            chunks = try walk([UInt8](data))
        } catch let failure as WalkFailure {
            return [Violation(kind: failure.kind, chunk: failure.chunk, offset: failure.offset)]
        } catch {
            // walk only throws WalkFailure; anything else still counts as unparsable.
            return [Violation(kind: "structure", chunk: "", offset: 0)]
        }
        return chunks.filter { !allowed.contains($0.type) }
            .map { Violation(kind: "notAllowed", chunk: $0.type, offset: $0.start) }
    }

    // MARK: the walk

    /// One chunk's place in the input. `start` is the offset of its length field, `end` is one
    /// past its CRC.
    struct Chunk {
        let type: String
        let start: Int
        let end: Int
        /// Bit 5 of the first type byte is 0 (an uppercase letter): a decoder must understand it.
        let isCritical: Bool
    }

    /// Why the walk stopped. `error` is what `strip` throws; `kind`, `chunk` and `offset` are what
    /// `check` reports.
    struct WalkFailure: Error {
        let error: ScrubError
        let kind: String
        let chunk: String
        let offset: Int

        static func structure(_ why: String, chunk: String, offset: Int) -> WalkFailure {
            WalkFailure(error: .structure(why), kind: "structure", chunk: chunk, offset: offset)
        }
    }

    /// Parses the whole file or throws. Shared by `strip` and `check` so the two can never
    /// disagree about where chunks are. Rules:
    /// - the 8-byte signature;
    /// - every length is bounds-checked before it is used (never trusted to skip ahead);
    /// - every type is four ASCII letters; every CRC is verified, kept chunks or not;
    /// - IHDR comes first, has length 13 and legal field values, and appears once;
    /// - PLTE only for a palette image (colour type 3), where it is required, once, before IDAT,
    ///   1 to 2^bit depth entries (at most 256);
    /// - each allowlisted ancillary chunk (sRGB) at most once, before the first IDAT, with its
    ///   exact length and checked values (`ancillaryProblem`);
    /// - IDAT chunks consecutive, at least one before IEND;
    /// - the walk stops at IEND, which must be empty and must end exactly at the end of the data.
    static func walk(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= signature.count, bytes[0..<signature.count].elementsEqual(signature) else {
            throw WalkFailure(error: .notPNG, kind: "notPNG", chunk: "", offset: 0)
        }

        var chunks: [Chunk] = []
        var header: Header?                 // set by IHDR, the first chunk
        var idat = IDATState.notYet
        var seen: Set<String> = []          // allowlisted non-IDAT chunks seen so far
        var i = signature.count

        while i < bytes.count {
            // The 12 fixed bytes (length, type, CRC) must fit before anything is read.
            guard bytes.count - i >= 12 else {
                throw WalkFailure(error: .truncated(offset: i), kind: "truncated", chunk: "", offset: i)
            }
            guard let length = chunkLength(bytes, at: i) else {
                throw WalkFailure(error: .truncated(offset: i), kind: "truncated", chunk: "", offset: i)
            }
            // Bounds check against what is left, written as a subtraction so it cannot overflow.
            guard length <= bytes.count - i - 12 else {
                throw WalkFailure(error: .truncated(offset: i), kind: "truncated", chunk: "", offset: i)
            }

            let typeBytes = bytes[i + 4..<i + 8]
            guard typeBytes.allSatisfy(isASCIILetter) else {
                throw WalkFailure.structure("chunk type at byte \(i) is not four letters", chunk: "", offset: i)
            }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let dataEnd = i + 8 + length
            let end = dataEnd + 4

            // The CRC covers type + data.
            let stored = bytes[dataEnd..<end].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard crc32(bytes[i + 4..<dataEnd]) == stored else {
                throw WalkFailure(error: .badCRC(chunk: type, offset: i), kind: "badCRC", chunk: type, offset: i)
            }

            // IHDR first, exactly once, 13 bytes of data.
            if chunks.isEmpty {
                guard type == "IHDR" else {
                    throw WalkFailure.structure("first chunk is \(type), not IHDR", chunk: "IHDR", offset: i)
                }
                // Header checks the length (13) and every field value.
                guard let h = Header(bytes[i + 8..<dataEnd]) else {
                    throw WalkFailure.structure("IHDR must be 13 bytes of legal values", chunk: "IHDR", offset: i)
                }
                header = h
            } else if type == "IHDR" {
                throw WalkFailure.structure("a second IHDR at byte \(i)", chunk: "IHDR", offset: i)
            }
            // Set above: the first chunk is IHDR, or the walk already threw.
            let h = header!

            // IDAT chunks form one unbroken run. Any other chunk after the run starts ends it.
            if type == "IDAT" {
                guard idat != .ended else {
                    throw WalkFailure.structure("IDAT chunks are not consecutive", chunk: "IDAT", offset: i)
                }
                guard h.colourType != 3 || seen.contains("PLTE") else {
                    throw WalkFailure.structure("palette image has no PLTE before IDAT", chunk: "PLTE", offset: i)
                }
                idat = .inRun
            } else if idat == .inRun {
                idat = .ended
            }

            // PLTE: palette images only, once, sized in whole entries. On RGB and RGBA images PLTE
            // is only a suggestion, so its bytes would be free; refused there. "Before IDAT"
            // follows from the rest: a palette image's IDAT needs a PLTE first (above), and a
            // second PLTE is refused.
            if type == "PLTE" {
                let entries = length / 3
                let maxEntries = min(256, 1 << h.bitDepth)
                guard h.colourType == 3, !seen.contains("PLTE"),
                      length % 3 == 0, entries >= 1, entries <= maxEntries else {
                    throw WalkFailure.structure("PLTE is misplaced, repeated or the wrong size", chunk: "PLTE", offset: i)
                }
                seen.insert("PLTE")
            }

            // Allowlisted ancillary chunks: once each, before IDAT, exact length and values.
            if typeBytes.first! & 0x20 != 0, allowed.contains(type) {
                guard idat == .notYet else {
                    throw WalkFailure.structure("\(type) after IDAT", chunk: type, offset: i)
                }
                guard !seen.contains(type) else {
                    throw WalkFailure.structure("a second \(type)", chunk: type, offset: i)
                }
                if let why = ancillaryProblem(type, bytes[i + 8..<dataEnd]) {
                    throw WalkFailure.structure(why, chunk: type, offset: i)
                }
                seen.insert(type)
            }

            chunks.append(Chunk(type: type, start: i, end: end, isCritical: typeBytes.first! & 0x20 == 0))

            if type == "IEND" {
                guard length == 0 else {
                    throw WalkFailure.structure("IEND has length \(length), not 0", chunk: "IEND", offset: i)
                }
                guard idat != .notYet else {
                    throw WalkFailure.structure("no IDAT before IEND", chunk: "IDAT", offset: i)
                }
                // The walk ends here. Anything after IEND, a chunk or a single byte, is refused,
                // never trimmed or walked into.
                guard end == bytes.count else {
                    throw WalkFailure(error: .trailingBytes(offset: end), kind: "trailingBytes",
                                      chunk: "IEND", offset: end)
                }
                return chunks
            }
            i = end
        }

        // Ran out of data without an IEND. A signature with nothing after it has no IHDR either.
        if chunks.isEmpty {
            throw WalkFailure.structure("no IHDR", chunk: "IHDR", offset: i)
        }
        throw WalkFailure.structure("no IEND", chunk: "IEND", offset: i)
    }

    /// The 4-byte big-endian length field at `i` (the caller has checked 4 bytes are there), or nil
    /// when it is over the spec cap of 2^31 - 1. Read as UInt32 and capped before converting to
    /// Int, so the bound holds on a 32-bit Int too, where 0xFFFFFFFF would not fit.
    static func chunkLength(_ bytes: [UInt8], at i: Int) -> Int? {
        let length32 = bytes[i..<i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length32 <= UInt32(maxChunkLength) else { return nil }
        return Int(length32)
    }

    /// Where the walk is relative to the IDAT run.
    enum IDATState { case notYet, inRun, ended }

    /// The IHDR fields the other rules need, built only from legal values: width and height
    /// 1 to 2^31 - 1, a colour type and bit depth pair the spec allows, compression and filter
    /// method 0, interlace 0 or 1. Every one of the 13 bytes is checked, so none can hide data.
    struct Header {
        let colourType: UInt8
        let bitDepth: UInt8

        init?(_ d: ArraySlice<UInt8>) {
            let b = Array(d)                       // re-index from 0
            guard b.count == 13 else { return nil }
            let width = b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let height = b[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let depth = b[8], colour = b[9]
            let depths: [UInt8: [UInt8]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
            guard (1...0x7FFF_FFFF).contains(width), (1...0x7FFF_FFFF).contains(height),
                  depths[colour]?.contains(depth) == true,
                  b[10] == 0, b[11] == 0, b[12] <= 1 else { return nil }
            colourType = colour
            bitDepth = depth
        }
    }

    /// nil when an allowlisted ancillary chunk's data is exactly what the spec allows, else why
    /// not. sRGB is the only allowlisted ancillary chunk.
    static func ancillaryProblem(_ type: String, _ d: ArraySlice<UInt8>) -> String? {
        let b = Array(d)                           // re-index from 0
        switch type {
        case "sRGB":
            // One byte: the rendering intent, 0 to 3.
            return b.count == 1 && b[0] <= 3 ? nil : "sRGB must be 1 byte, intent 0 to 3"
        default:
            // An allowlisted ancillary chunk with no rule above: refuse rather than keep unchecked.
            return "\(type) has no rule"
        }
    }

    private static func isASCIILetter(_ b: UInt8) -> Bool {
        (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    // MARK: CRC-32

    /// CRC-32 as PNG and zlib define it (reflected polynomial 0xEDB88320, start and final XOR
    /// 0xFFFFFFFF). One table of 256 entries, built once, then one lookup per byte.
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Entry n is the CRC of the single byte n, before the final XOR.
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}
