// Swift. The image types the redact engine writes, picked from a file extension, and the one place
// the Q4 policy is read. Both the output name and the encoder go through `output(...)`, so the
// extension and the container cannot disagree. Foundation only: this file must compile on Windows.
import Foundation

public enum ImageFormat: String, Equatable, CaseIterable, Sendable {
    case png, jpeg, heic, tiff, gif, bmp

    /// Formats that throw detail away when encoded, so verify must allow for compression noise.
    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic: return true
        case .png, .tiff, .gif, .bmp: return false
        }
    }

    /// png; jpg and jpeg; heic; tif and tiff; gif; bmp. Case-insensitive. nil for anything else,
    /// including the read-only types below.
    public static func forExtension(_ ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return nil
        }
    }

    /// Readable, never written: the Q4 policy decides. webp, heif, avif, jxl.
    public static let readOnlyExtensions: Set<String> = ["webp", "heif", "avif", "jxl"]

    /// What the engine will write for one source file.
    public struct Output: Equatable, Sendable {
        public let format: ImageFormat
        /// The source's extension, lowercased as found ("jpeg" stays "jpeg"); "png" when converted.
        public let fileExtension: String
        /// True when the source type cannot be written and the copy is a PNG instead.
        public let converted: Bool

        public init(format: ImageFormat, fileExtension: String, converted: Bool) {
            self.format = format
            self.fileExtension = fileExtension
            self.converted = converted
        }
    }

    /// The only reader of the Q4 policy. nil means "this run cannot write that type".
    public static func output(forSourceExtension ext: String,
                              policy: UnwritableFormatPolicy = RedactDefaults.webP) -> Output? {
        let lower = ext.lowercased()
        if let format = forExtension(lower) {
            return Output(format: format, fileExtension: lower, converted: false)
        }
        guard readOnlyExtensions.contains(lower) else { return nil }
        switch policy {
        case .writePNG: return Output(format: .png, fileExtension: "png", converted: true)
        case .refuse: return nil
        }
    }
}
