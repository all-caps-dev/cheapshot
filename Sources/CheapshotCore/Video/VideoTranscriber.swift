import Foundation

public struct VideoSegment: Equatable {
    public var time: TimeInterval
    public var text: String
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

public struct VideoTranscript {
    public var segments: [VideoSegment]
    public var frameCount: Int
    public var imageTokens: Int
    public var redactions: RedactionReport
}

/// Frames -> OCR -> redaction -> drop screens too similar to the last one -> timestamped segments.
public struct VideoTranscriber {
    public let source: FrameSource
    public let dedupe: Double
    public let minConfidence: Float
    public let redactor: Redactor?

    public init(source: FrameSource, dedupe: Double = 0.90, minConfidence: Float = 0.3, redactor: Redactor? = Redactor()) {
        self.source = source; self.dedupe = dedupe; self.minConfidence = minConfidence; self.redactor = redactor
    }

    public func transcribe(_ video: URL, maxFrames: Int) async throws -> VideoTranscript {
        var segments: [VideoSegment] = []
        var lastText = ""
        var frameCount = 0, imageTokens = 0
        var report = RedactionReport()
        for try await frame in try source.frames(of: video, maxFrames: maxFrames) {
            frameCount += 1
            imageTokens += Tokens.image(width: frame.image.width, height: frame.image.height)
            guard let rendered = try? OCR.recognizeLayout(image: frame.image, minConfidence: minConfidence) else { continue }
            var text = Layout.text(rendered)
            if let r = redactor {
                let (t, rep) = r.redact(text)
                text = t
                for (k, v) in rep.counts { report.counts[k, default: 0] += v }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if Self.similarity(trimmed, lastText) >= dedupe { continue }
            segments.append(VideoSegment(time: frame.time, text: trimmed))
            lastText = trimmed
        }
        return VideoTranscript(segments: segments, frameCount: frameCount, imageTokens: imageTokens, redactions: report)
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
