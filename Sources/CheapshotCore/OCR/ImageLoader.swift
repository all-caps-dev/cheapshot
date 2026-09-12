import Foundation
import AppKit

public enum ImageLoader {
    public static func load(path: String) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public static func pixelSize(path: String) -> (width: Int, height: Int)? {
        guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
