// Swift. Tests for ImageFormat: which extensions the redact engine writes, and the Q4 policy for
// types it can read but not write (webp, heif, avif, jxl).
import XCTest
@testable import CheapshotPortable

final class ImageFormatTests: XCTestCase {
    func testExtensionTableAndUnwritablePolicy() {
        // Every writable extension, any case.
        let table: [(String, ImageFormat)] = [
            ("png", .png), ("jpg", .jpeg), ("jpeg", .jpeg), ("heic", .heic),
            ("tif", .tiff), ("tiff", .tiff), ("gif", .gif), ("bmp", .bmp),
        ]
        for (ext, format) in table {
            XCTAssertEqual(ImageFormat.forExtension(ext), format, ext)
            XCTAssertEqual(ImageFormat.forExtension(ext.uppercased()), format, ext.uppercased())
            // Written as itself, extension kept as found but lowercased, under both policies.
            let kept = ImageFormat.Output(format: format, fileExtension: ext, converted: false)
            XCTAssertEqual(ImageFormat.output(forSourceExtension: ext, policy: .writePNG), kept, ext)
            XCTAssertEqual(ImageFormat.output(forSourceExtension: ext, policy: .refuse), kept, ext)
            XCTAssertEqual(ImageFormat.output(forSourceExtension: ext.uppercased(), policy: .refuse), kept, ext)
        }
        XCTAssertEqual(ImageFormat.output(forSourceExtension: "JPEG", policy: .refuse)?.fileExtension, "jpeg",
                       "jpeg stays jpeg, never renamed to jpg")
        XCTAssertEqual(Set(table.map { $0.1 }), Set(ImageFormat.allCases), "every case has an extension")

        // Lossy formats.
        XCTAssertEqual(Set(ImageFormat.allCases.filter { $0.isLossy }), [.jpeg, .heic])

        // Read-only types: PNG under .writePNG, nil under .refuse. Never writable as themselves.
        XCTAssertEqual(ImageFormat.readOnlyExtensions, ["webp", "heif", "avif", "jxl"])
        for ext in ["webp", "heif", "avif", "jxl", "WEBP", "Heif"] {
            XCTAssertNil(ImageFormat.forExtension(ext), ext)
            XCTAssertEqual(ImageFormat.output(forSourceExtension: ext, policy: .writePNG),
                           ImageFormat.Output(format: .png, fileExtension: "png", converted: true), ext)
            XCTAssertNil(ImageFormat.output(forSourceExtension: ext, policy: .refuse), ext)
        }

        // Anything else is nothing, under both policies.
        for ext in ["", "txt", "pdf", "svg", "png.webp", ".png", "pn g"] {
            XCTAssertNil(ImageFormat.forExtension(ext), ext)
            XCTAssertNil(ImageFormat.output(forSourceExtension: ext, policy: .writePNG), ext)
            XCTAssertNil(ImageFormat.output(forSourceExtension: ext, policy: .refuse), ext)
        }
    }
}
