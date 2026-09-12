import Foundation
import CoreGraphics

/// One recognized line. `bbox` is in pixels (or PDF points) with a top-left origin.
public struct OCRLine: Equatable {
    public var text: String
    public var bbox: CGRect
    public var confidence: Float
    public init(text: String, bbox: CGRect, confidence: Float) { self.text = text; self.bbox = bbox; self.confidence = confidence }
}

public struct OCRResult: Equatable {
    public var lines: [OCRLine]
    public var width: Int
    public var height: Int
    public init(lines: [OCRLine], width: Int, height: Int) { self.lines = lines; self.width = width; self.height = height }
}

/// A line after layout: numbered, indented, and flagged if it sits inside a code fence.
public struct RenderedLine: Equatable {
    public var n: Int
    public var text: String
    public var bbox: CGRect
    public var confidence: Float
    public var fenced: Bool
    public init(n: Int, text: String, bbox: CGRect, confidence: Float, fenced: Bool) {
        self.n = n; self.text = text; self.bbox = bbox; self.confidence = confidence; self.fenced = fenced
    }
}

/// Pure arithmetic on bounding boxes. Vision drops leading whitespace; a fixed-width font
/// has a constant per-character width, so runs of lines with the same cell width are code,
/// and their x offset divided by the cell width is the indentation.
public enum Layout {
    public static let monospaceTolerance: CGFloat = 0.08
    public static let minimumVotingLines = 3
    public static let minimumVotingChars = 4
    public static let maxIndent = 40

    public static func cellWidth(_ line: OCRLine) -> CGFloat? {
        let n = line.text.count
        guard n >= minimumVotingChars, line.bbox.width > 0 else { return nil }
        return line.bbox.width / CGFloat(n)
    }

    /// Top to bottom, then left to right. Two lines whose tops are within half a line height
    /// of each other are on the same row.
    static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { a, b in
            let tolerance = min(a.bbox.height, b.bbox.height) * 0.5
            if abs(a.bbox.minY - b.bbox.minY) > tolerance { return a.bbox.minY < b.bbox.minY }
            return a.bbox.minX < b.bbox.minX
        }
    }

    static func median(_ xs: [CGFloat]) -> CGFloat {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Runs of consecutive lines (in the given order) whose voting lines' cell widths stay within
    /// `monospaceTolerance` of the run's median. Returns runs with at least `minimumVotingLines` voters.
    public static func monospaceRuns(_ lines: [OCRLine]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        var voters: [CGFloat] = []

        func close(at end: Int) {
            if voters.count >= minimumVotingLines { runs.append(start..<end) }
            voters = []
        }

        for (i, line) in lines.enumerated() {
            guard let cw = cellWidth(line) else { continue }          // short line: joins, does not vote
            if voters.isEmpty {
                // Drop leading short lines from the run: start at the first voter.
                start = i
                voters = [cw]
                continue
            }
            let m = median(voters)
            if abs(cw - m) / m <= monospaceTolerance {
                voters.append(cw)
            } else {
                close(at: i)
                start = i
                voters = [cw]
            }
        }
        close(at: lines.count)
        // Trim trailing short lines only if they come after the last voter? They stay: a closing "}" is code.
        return runs
    }

    public static func render(_ lines: [OCRLine]) -> [RenderedLine] {
        let s = sorted(lines)
        var out = s.enumerated().map { i, l in
            RenderedLine(n: i + 1, text: l.text, bbox: l.bbox, confidence: l.confidence, fenced: false)
        }
        for run in monospaceRuns(s) {
            let cws = run.compactMap { cellWidth(s[$0]) }
            guard !cws.isEmpty else { continue }
            let cell = median(cws)
            let minX = run.map { s[$0].bbox.minX }.min() ?? 0
            for i in run {
                let indent = min(maxIndent, max(0, Int(((s[i].bbox.minX - minX) / cell).rounded())))
                out[i].text = String(repeating: " ", count: indent) + s[i].text
                out[i].fenced = true
            }
        }
        return out
    }

    /// Joins lines, wrapping each fenced stretch in ``` fences.
    public static func text(_ lines: [RenderedLine]) -> String {
        var parts: [String] = []
        var open = false
        for l in lines {
            if l.fenced && !open { parts.append("```"); open = true }
            if !l.fenced && open { parts.append("```"); open = false }
            parts.append(l.text)
        }
        if open { parts.append("```") }
        return parts.joined(separator: "\n")
    }
}
