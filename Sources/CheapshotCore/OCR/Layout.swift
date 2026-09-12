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
    /// How tightly a run's cell widths must agree, measured as the spread of the run's voting
    /// lines (max minus min) over their median. Long proportional prose lines converge on the
    /// font's average character width: measured with CoreText at 14pt in a 460pt column,
    /// Helvetica spreads 7.4%, Times 9.5% and SF 9.5% across five or six lines, so anything
    /// near 8% fences whole paragraphs. Monospace text on tight boxes stays under 2%.
    /// Task 10 retunes this against a real terminal screenshot if fences start vanishing.
    public static let monospaceTolerance: CGFloat = 0.03
    public static let minimumVotingLines = 3
    public static let minimumVotingChars = 4
    public static let maxIndent = 40

    public static func cellWidth(_ line: OCRLine) -> CGFloat? {
        let n = line.text.count
        guard n >= minimumVotingChars, line.bbox.width > 0 else { return nil }
        return line.bbox.width / CGFloat(n)
    }

    /// The typical line height, used to quantize rows. Falls back to 1 for empty or degenerate input.
    static func rowPitch(_ lines: [OCRLine]) -> CGFloat {
        let heights = lines.map(\.bbox.height).filter { $0 > 0 }
        guard !heights.isEmpty else { return 1 }
        let m = median(heights)
        return m > 0 ? m : 1
    }

    /// Top to bottom, then left to right. Rows are quantized to a multiple of the median line
    /// height first, so the comparison is a total order on `(row, minX, minY)`. Comparing raw
    /// `minY` against a tolerance is not transitive (a and b within half a line, b and c within
    /// half a line, a and c not), which lets the result depend on the input order: dense pages
    /// came back reversed and columns offset by half a line interleaved wrongly.
    static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        let pitch = rowPitch(lines)
        // `Int(_:)` traps on a non-finite value, so a NaN box would crash the sort. Park those
        // rows at the end instead.
        func row(_ y: CGFloat) -> Int {
            let r = (y / pitch).rounded()
            return r.isFinite ? Int(r) : Int.max
        }
        return lines.sorted { a, b in
            let ra = row(a.bbox.minY)
            let rb = row(b.bbox.minY)
            if ra != rb { return ra < rb }
            if a.bbox.minX != b.bbox.minX { return a.bbox.minX < b.bbox.minX }
            return a.bbox.minY < b.bbox.minY
        }
    }

    static func median(_ xs: [CGFloat]) -> CGFloat {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// True when a set of cell widths is tight enough to be one fixed-width font: the whole
    /// spread, not just the newest line against the running median, has to fit the tolerance.
    /// Comparing only against the running median lets a run drift arbitrarily far over many
    /// lines, which is how proportional paragraphs slipped through.
    static func isTight(_ widths: [CGFloat]) -> Bool {
        guard let lo = widths.min(), let hi = widths.max() else { return true }
        let m = median(widths)
        guard m > 0 else { return false }
        return (hi - lo) / m <= monospaceTolerance
    }

    /// Runs of consecutive lines (in the given order) whose voting lines' cell widths stay within
    /// `monospaceTolerance`. A run needs at least `minimumVotingLines` voters, spans from its
    /// first voter to its last, and then absorbs the short lines trailing it only while they sit
    /// horizontally inside the block: an aligned closing brace is code, a far-left status label
    /// or gutter digit is not, and letting one in would drag the run's left edge with it.
    public static func monospaceRuns(_ lines: [OCRLine]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0                    // index of the run's first voter
        var lastVoter = -1               // index of the run's last voter
        var widths: [CGFloat] = []
        var voterMinX: [CGFloat] = []

        func close(upTo limit: Int) {
            defer { widths = []; voterMinX = []; lastVoter = -1 }
            guard widths.count >= minimumVotingLines, lastVoter >= start else { return }
            let cell = median(widths)
            let minX = voterMinX.min() ?? 0
            var end = lastVoter + 1
            while end < limit, cellWidth(lines[end]) == nil, lines[end].bbox.minX >= minX - 0.5 * cell {
                end += 1
            }
            runs.append(start..<end)
        }

        func open(at i: Int, _ cw: CGFloat, _ minX: CGFloat) {
            start = i; lastVoter = i; widths = [cw]; voterMinX = [minX]
        }

        for (i, line) in lines.enumerated() {
            guard let cw = cellWidth(line) else { continue }          // short line: may join, does not vote
            if widths.isEmpty {
                // Drop leading short lines from the run: start at the first voter.
                open(at: i, cw, line.bbox.minX)
            } else if isTight(widths + [cw]) {
                widths.append(cw); voterMinX.append(line.bbox.minX); lastVoter = i
            } else {
                close(upTo: i)
                open(at: i, cw, line.bbox.minX)
            }
        }
        close(upTo: lines.count)
        return runs
    }

    public static func render(_ lines: [OCRLine]) -> [RenderedLine] {
        let s = sorted(lines)
        var out = s.enumerated().map { i, l in
            RenderedLine(n: i + 1, text: l.text, bbox: l.bbox, confidence: l.confidence, fenced: false)
        }
        for run in monospaceRuns(s) {
            // Only voting lines set the cell width and the left edge; a short line inside the run
            // that starts further left than the block would otherwise shift every indent right.
            let voting = run.compactMap { i in cellWidth(s[i]).map { (i, $0) } }
            guard !voting.isEmpty else { continue }
            let cell = median(voting.map(\.1))
            let minX = voting.map { s[$0.0].bbox.minX }.min() ?? 0
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
