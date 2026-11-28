import XCTest
import AppKit
@testable import CheapshotCLI
import CheapshotCore

/// A clipboard held in memory, for tests. Text can be put on it to prove the CLI never reads it:
/// `readImage` and `readFileURL` ignore it, the way `PasteboardClipboard` never asks for a
/// string type. Every read and write is counted, so a test can prove a run left it alone.
final class FakeClipboard: ClipboardSource {
    var image: Data?
    var fileURLs: [URL] = []
    var text: String?
    private(set) var changeCount = 1
    private(set) var reads = 0
    private(set) var writes: [ClipboardPayload] = []
    /// Called on every image read, so a test can copy something mid-run (the change-count race).
    var onRead: (() -> Void)?

    init(image: Data? = nil, fileURLs: [URL] = [], text: String? = nil) {
        self.image = image; self.fileURLs = fileURLs; self.text = text
    }

    /// The user copied something: content changes and the count moves.
    func userCopied(text: String) { image = nil; fileURLs = []; self.text = text; changeCount += 1 }

    func readImage() -> Data? { reads += 1; onRead?(); return image }
    func readFileURL() -> URL? { reads += 1; return fileURLs.count == 1 ? fileURLs[0] : nil }

    @discardableResult
    func replace(with payload: ClipboardPayload) -> Bool {
        writes.append(payload)
        image = nil; fileURLs = []; text = nil
        switch payload {
        case .text(let s): text = s
        case .png(let d): image = d
        }
        changeCount += 1
        return true
    }
}

final class ClipboardTests: XCTestCase {
    // MARK: - the seam

    func testCLIIODefaultsToNoClipboard() {
        // A test or embedder that builds its own CLIIO must never reach the real pasteboard.
        let io = CLIIO(out: { _ in }, err: { _ in }, readStdin: { "" }, environment: [:], home: "/tmp")
        XCTAssertNil(io.clipboard)
    }

    func testStandardCLIIOHasThePasteboardOnMacOS() {
        // Building `standard` must not read anything; it only wraps the general pasteboard.
        XCTAssertTrue(CLIIO.standard.clipboard is PasteboardClipboard)
    }

    func testFakeNeverHandsOutText() {
        let fake = FakeClipboard(text: "hunter2")
        XCTAssertNil(fake.readImage())
        XCTAssertNil(fake.readFileURL())
    }

    func testFakeReplaceLeavesOneItem() {
        let fake = FakeClipboard(image: Data([1, 2, 3]), text: "x")
        let before = fake.changeCount
        fake.replace(with: .text("redacted"))
        XCTAssertNil(fake.image)
        XCTAssertEqual(fake.text, "redacted")
        XCTAssertEqual(fake.writes, [.text("redacted")])
        XCTAssertGreaterThan(fake.changeCount, before)
    }

    // MARK: - PasteboardClipboard on a private, uniquely named pasteboard

    /// A pasteboard no other process uses, released after each test. Skips with a printed
    /// reason when the machine has no pasteboard server (a headless runner).
    func privatePasteboard() throws -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("cheapshot-test-\(UUID().uuidString)"))
        pb.clearContents()
        let probe = "cheapshot-probe"
        guard pb.setString(probe, forType: NSPasteboard.PasteboardType("org.cheapshot.probe")),
              pb.string(forType: NSPasteboard.PasteboardType("org.cheapshot.probe")) == probe else {
            pb.releaseGlobally()
            throw XCTSkip("no pasteboard server on this machine; the NSPasteboard integration tests need one")
        }
        pb.clearContents()
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testTextOnlyPasteboardReadsAsNothing() throws {
        let pb = try privatePasteboard()
        pb.setString("AKIAIOSFODNN7EXAMPLE", forType: .string)
        pb.setString("/Users/someone/secret.png", forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        let clip = PasteboardClipboard(pb)
        XCTAssertNil(clip.readImage(), "text must never be read as an image")
        XCTAssertNil(clip.readFileURL(), "a path typed as text is not a copied file")
    }

    func testEmptyPasteboardReadsAsNothing() throws {
        let clip = PasteboardClipboard(try privatePasteboard())
        XCTAssertNil(clip.readImage())
        XCTAssertNil(clip.readFileURL())
    }

    func testReadsPNGBytes() throws {
        let pb = try privatePasteboard()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        pb.setData(png, forType: .png)
        XCTAssertEqual(PasteboardClipboard(pb).readImage(), png)
    }

    func testPrefersPNGOverTIFF() throws {
        let pb = try privatePasteboard()
        let png = Data([0x89, 0x50, 0x4E, 0x47]), tiff = Data([0x4D, 0x4D, 0x00, 0x2A])
        pb.declareTypes([.tiff, .png], owner: nil)
        pb.setData(tiff, forType: .tiff)
        pb.setData(png, forType: .png)
        XCTAssertEqual(PasteboardClipboard(pb).readImage(), png)
    }

    func testReadsJPEGAndHEICByName() throws {
        for uti in ["public.jpeg", "public.heic"] {
            let pb = try privatePasteboard()
            let bytes = Data(uti.utf8)
            pb.setData(bytes, forType: NSPasteboard.PasteboardType(uti))
            XCTAssertEqual(PasteboardClipboard(pb).readImage(), bytes, uti)
        }
    }

    func testReadsOneFileURL() throws {
        let pb = try privatePasteboard()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shot.png")
        XCTAssertTrue(pb.writeObjects([url as NSURL]))
        XCTAssertEqual(PasteboardClipboard(pb).readFileURL(), url.standardizedFileURL)
    }

    func testTwoFileURLsReadAsNothing() throws {
        let pb = try privatePasteboard()
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        XCTAssertTrue(pb.writeObjects([a as NSURL, b as NSURL]))
        XCTAssertNil(PasteboardClipboard(pb).readFileURL())
    }

    func testWebURLIsNotAFileURL() throws {
        let pb = try privatePasteboard()
        XCTAssertTrue(pb.writeObjects([URL(string: "https://example.com/a.png")! as NSURL]))
        XCTAssertNil(PasteboardClipboard(pb).readFileURL())
    }

    func testReplaceClearsThenWritesOneItem() throws {
        let pb = try privatePasteboard()
        pb.setString("AKIAIOSFODNN7EXAMPLE", forType: .string)
        pb.setData(Data([1, 2, 3]), forType: .png)
        let clip = PasteboardClipboard(pb)
        let before = clip.changeCount
        XCTAssertTrue(clip.replace(with: .text("[REDACTED:AWS_KEY]")))
        XCTAssertGreaterThan(clip.changeCount, before)
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertNil(pb.data(forType: .png), "the old image must be gone")
        XCTAssertEqual(pb.string(forType: .string), "[REDACTED:AWS_KEY]")

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(clip.replace(with: .png(png)))
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        // `pb.types` also lists the TIFF and legacy names the pasteboard server can convert
        // to; the item itself holds only the PNG.
        XCTAssertEqual(pb.pasteboardItems?.first?.types, [.png])
        XCTAssertNil(pb.string(forType: .string), "the old text must be gone")
    }
}
