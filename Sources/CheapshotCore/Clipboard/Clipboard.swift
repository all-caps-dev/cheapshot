import Foundation
#if os(macOS)
import AppKit
#endif

// Swift: the clipboard seam for `cheapshot --clipboard` (NOV-155, CHE-84) and later the Mac app's
// hotkey action. The CLI talks to a `ClipboardSource`; tests hand it a fake, the binary hands it
// the general pasteboard. Only image bytes and file URLs are ever read. Clipboard text is never
// read: a copied password has no keyword beside it, so a rule may not match it, and printing it
// would hand it to whoever ran the command (plan section 4.3).

/// What `replace(with:)` puts back on the clipboard as its only item.
public enum ClipboardPayload: Equatable {
    /// Redacted text, written as plain UTF-8 text.
    case text(String)
    /// A masked PNG, written as `public.png`.
    case png(Data)
}

/// The clipboard as `--clipboard` sees it.
public protocol ClipboardSource: AnyObject {
    /// Moves every time anything writes to the clipboard. Read before OCR and again before any
    /// write, so a copy the user made while a slow read ran is never overwritten.
    var changeCount: Int { get }
    /// Image bytes (PNG, TIFF, JPEG or HEIC, in that order of preference), or nil. Never text.
    /// Nil whenever the clipboard holds any file URL: a Finder copy also puts the file's icon on
    /// the clipboard as an image, and that icon must never be read in place of the file. So file
    /// URLs always win, and a caller cannot get the order wrong.
    func readImage() -> Data?
    /// Every file URL on the clipboard (files copied in Finder), as path URLs, in clipboard order.
    /// Finder's file reference URLs (`file:///.file/id=...`) are resolved to their paths. Empty
    /// when there are none. Callers that read one input refuse two or more rather than guess.
    func readFileURLs() -> [URL]
    /// How many clipboard items carry a file URL at all, resolvable or not. Callers count
    /// copied files with this, never with `readFileURLs().count`: a copied file that was since
    /// deleted (or whose volume was unmounted) still counts, so two copied files with one gone
    /// is still two, and one gone file is reported as gone rather than as an empty clipboard.
    var fileItemCount: Int { get }
    /// Clears the clipboard, then writes `payload` as its only item. False when the write failed,
    /// and the clipboard is then already empty: the old contents are gone either way.
    @discardableResult func replace(with payload: ClipboardPayload) -> Bool
}

public extension ClipboardSource {
    /// Default for conformers whose file URLs always resolve: one item per URL.
    var fileItemCount: Int { readFileURLs().count }
    /// True when any item carries a file URL; `readImage()` is nil then.
    var holdsFileItems: Bool { fileItemCount > 0 }

    /// The file URL when the clipboard holds exactly one, else nil (none, or two or more).
    /// Counted by file items, so two copied files with one gone is still nil, never the survivor.
    func readFileURL() -> URL? {
        let urls = readFileURLs()
        return urls.count == 1 && fileItemCount == 1 ? urls[0] : nil
    }
}

#if os(macOS)
/// `ClipboardSource` over an `NSPasteboard`: the general one for the CLI, a uniquely named one
/// in the integration test.
public final class PasteboardClipboard: ClipboardSource {
    public let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// The image types read, most preferred first. Each is asked for by name, so no string type
    /// is ever touched (`NSImage(pasteboard:)` would also accept PDF and text-backed types).
    public static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    public var changeCount: Int { pasteboard.changeCount }

    public func readImage() -> Data? {
        // File URLs win (see the protocol): any item carrying public.file-url means the image
        // types on the clipboard are Finder's icon or thumbnail, not something to read.
        if holdsFileItems { return nil }
        for type in Self.imageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
        }
        return nil
    }

    public var fileItemCount: Int {
        (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }.count
    }

    public func readFileURLs() -> [URL] {
        // public.file-url on each item, decoded by hand rather than through readObjects, so the
        // read never falls back to a text type that merely looks like a path. Finder writes file
        // reference URLs (file:///.file/id=...); filePathURL resolves them, and an item whose
        // reference no longer resolves (the file is gone) is dropped.
        (pasteboard.pasteboardItems ?? []).compactMap { item -> URL? in
            guard let data = item.data(forType: .fileURL),
                  let raw = URL(dataRepresentation: data, relativeTo: nil), raw.isFileURL,
                  let url = (raw as NSURL).filePathURL else { return nil }
            return url.standardizedFileURL
        }
    }

    @discardableResult
    public func replace(with payload: ClipboardPayload) -> Bool {
        pasteboard.clearContents()
        switch payload {
        case .text(let s): return pasteboard.setString(s, forType: .string)
        case .png(let d): return pasteboard.setData(d, forType: .png)
        }
    }
}
#endif
