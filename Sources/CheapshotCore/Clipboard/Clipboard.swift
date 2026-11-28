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
    func readImage() -> Data?
    /// The file URL when the clipboard holds exactly one (a file copied in Finder), else nil.
    /// Two or more files are nil too: the mode reads one input, and guessing which is worse.
    func readFileURL() -> URL?
    /// Clears the clipboard, then writes `payload` as its only item. False when the write failed.
    @discardableResult func replace(with payload: ClipboardPayload) -> Bool
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
        for type in Self.imageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
        }
        return nil
    }

    public func readFileURL() -> URL? {
        // public.file-url on each item, decoded by hand rather than through readObjects, so the
        // read never falls back to a text type that merely looks like a path.
        let urls = (pasteboard.pasteboardItems ?? []).compactMap { item -> URL? in
            guard let data = item.data(forType: .fileURL),
                  let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        return urls.count == 1 ? urls[0] : nil
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
