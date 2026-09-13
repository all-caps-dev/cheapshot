import Foundation
import CoreGraphics

public struct VideoSegment: Equatable {
    public var time: TimeInterval
    public var text: String
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

public struct VideoTranscript {
    public var segments: [VideoSegment]
    public var frameCount: Int
    /// Frames Vision threw on. A failed frame is not in `frameCount` or `imageTokens`: no text came
    /// back, so nothing was read and nothing was saved (runImages skips the same way). A run where
    /// every frame fails throws instead of returning.
    public var failedFrames: Int
    public var imageTokens: Int
    public var redactions: RedactionReport
}

/// Frames -> OCR -> redaction -> drop screens too similar to the last one -> timestamped segments.
public struct VideoTranscriber {
    public typealias OCRFunction = (CGImage, Float) throws -> [RenderedLine]

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public let source: FrameSource
    public let dedupe: Double
    public let minConfidence: Float
    public let redactor: Redactor?
    public let ocr: OCRFunction

    public init(source: FrameSource, dedupe: Double = 0.90, minConfidence: Float = 0.3, redactor: Redactor? = Redactor(),
                ocr: @escaping OCRFunction = { try OCR.recognizeLayout(image: $0, minConfidence: $1) }) {
        self.source = source; self.dedupe = dedupe; self.minConfidence = minConfidence; self.redactor = redactor; self.ocr = ocr
    }

    public func transcribe(_ video: URL, maxFrames: Int) async throws -> VideoTranscript {
        var segments: [VideoSegment] = []
        var lastText = ""
        var frameCount = 0, failedFrames = 0, imageTokens = 0
        var report = RedactionReport()
        var lastError: Error?
        for try await frame in try source.frames(of: video, maxFrames: maxFrames) {
            let rendered: [RenderedLine]
            do { rendered = try ocr(frame.image, minConfidence) }
            catch { failedFrames += 1; lastError = error; continue }
            frameCount += 1
            imageTokens += Tokens.image(width: frame.image.width, height: frame.image.height)
            var text = Layout.text(rendered)
            var frameReport = RedactionReport()
            if let r = redactor { (text, frameReport) = r.redact(text) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if Self.similarity(trimmed, lastText) >= dedupe { continue }
            segments.append(VideoSegment(time: frame.time, text: trimmed))
            lastText = trimmed
            // Counted only for kept frames: the ledger total should describe the transcript the
            // user got, not every duplicate screen that was OCR'd and dropped.
            for (k, v) in frameReport.counts { report.counts[k, default: 0] += v }
        }
        if frameCount == 0 && failedFrames > 0 {
            throw Failure(message: "OCR failed on all \(failedFrames) frame(s); last error: \(lastError.map { "\($0)" } ?? "unknown")")
        }
        return VideoTranscript(segments: segments, frameCount: frameCount, failedFrames: failedFrames,
                               imageTokens: imageTokens, redactions: report)
    }

    /// Cheap token-set overlap. Screen recordings repeat; near-identical frames are dropped.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let sa = Set(a.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        let sb = Set(b.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        if sa.isEmpty && sb.isEmpty { return 1 }
        if sa.isEmpty || sb.isEmpty { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    public static func stamp(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
