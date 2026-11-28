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

    /// The only chunks an output may hold. The four critical chunks, colour and size information,
    /// and Apple's iDOT (a decode hint ImageIO writes). Everything else is removed or refused.
    public static let allowed: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "sRGB", "iCCP", "pHYs", "gAMA", "cHRM", "sBIT", "iDOT",
    ]

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The PNG spec caps a chunk length at 2^31 - 1.
    static let maxChunkLength = 0x7FFF_FFFF

    /// Removes every chunk outside `allowed`. Throws on anything it does not fully understand
    /// (bad signature, bad CRC, truncation, bytes after IEND, an unknown critical chunk), so it
    /// never returns its input for bad data. The bytes it returns always pass `check`.
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
    /// walk (bad signature, bad CRC, truncation, missing IHDR, IDAT or IEND, bytes after IEND)
    /// is one violation naming the first problem, never [].
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
    /// - IHDR comes first, has length 13, and appears once;
    /// - at least one IDAT before IEND;
    /// - the walk stops at IEND, which must be empty and must end exactly at the end of the data.
    static func walk(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= signature.count, bytes[0..<signature.count].elementsEqual(signature) else {
            throw WalkFailure(error: .notPNG, kind: "notPNG", chunk: "", offset: 0)
        }

        var chunks: [Chunk] = []
        var sawIDAT = false
        var i = signature.count

        while i < bytes.count {
            // The 12 fixed bytes (length, type, CRC) must fit before anything is read.
            guard bytes.count - i >= 12 else {
                throw WalkFailure(error: .truncated(offset: i), kind: "truncated", chunk: "", offset: i)
            }
            let length = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            // Bounds check against what is left, written as a subtraction so it cannot overflow.
            guard length <= maxChunkLength, length <= bytes.count - i - 12 else {
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
                guard length == 13 else {
                    throw WalkFailure.structure("IHDR has length \(length), not 13", chunk: "IHDR", offset: i)
                }
            } else if type == "IHDR" {
                throw WalkFailure.structure("a second IHDR at byte \(i)", chunk: "IHDR", offset: i)
            }

            chunks.append(Chunk(type: type, start: i, end: end, isCritical: typeBytes.first! & 0x20 == 0))
            if type == "IDAT" { sawIDAT = true }

            if type == "IEND" {
                guard length == 0 else {
                    throw WalkFailure.structure("IEND has length \(length), not 0", chunk: "IEND", offset: i)
                }
                guard sawIDAT else {
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
