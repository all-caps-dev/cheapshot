import Foundation
import CoreGraphics

public struct VideoFrame {
    public let time: TimeInterval
    public let image: CGImage
    public init(time: TimeInterval, image: CGImage) { self.time = time; self.image = image }
}

/// Yields candidate frames in time order. The transcriber OCRs each and drops near-duplicates.
/// Image-typed, not path-typed: Vision wants a CGImage and the app has no temp dir to manage.
public protocol FrameSource {
    func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error>
}
