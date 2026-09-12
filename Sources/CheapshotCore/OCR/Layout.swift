import Foundation
import CoreGraphics

/// One recognized line. `bbox` is in pixels (or PDF points) with a top-left origin.
public struct OCRLine: Equatable {
    public var text: String
    public var bbox: CGRect
    public var confidence: Float
    /// Median per-word cell width in pixels, measured from Vision's word boxes. Nil when the
    /// line had fewer than three measurable words, or when the source has no word boxes at all
    /// (a PDF page, a synthetic fixture).
    public var cellWidth: CGFloat?
    /// Coefficient of variation of those per-word cell widths; 0 is perfectly fixed-width.
    /// Nil under the same conditions as `cellWidth`.
    public var cellVariation: CGFloat?
    public init(text: String, bbox: CGRect, confidence: Float,
                cellWidth: CGFloat? = nil, cellVariation: CGFloat? = nil) {
        self.text = text; self.bbox = bbox; self.confidence = confidence
        self.cellWidth = cellWidth; self.cellVariation = cellVariation
    }
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
    /// Tuned separately against real captures; see the layout tuning card.
    public static let monospaceTolerance: CGFloat = 0.03
    /// How much a single line's own words may disagree before the line stops being evidence of
    /// a fixed-width font. Measured per line as the coefficient of variation of its per-word
    /// cell widths: on a real capture, monospace lines land at 1 to 8% and proportional lines
    /// at 9 to 21%. A line above this does not vote and cannot start a run.
    public static let maxWordVariation: CGFloat = 0.08
    public static let minimumVotingLines = 3
    public static let minimumVotingChars = 4
    public static let maxIndent = 40

    /// The line's per-character cell width. Vision's word boxes give a far better estimate than
    /// the whole-line width over the string length, which is skewed by inserted spaces,
    /// corrected tokens and ink-fit boxes, so the measured field wins whenever it is present.
    public static func cellWidth(_ line: OCRLine) -> CGFloat? {
        let n = line.text.count
        guard n >= minimumVotingChars else { return nil }
        if let measured = line.cellWidth, measured > 0 { return measured }
        guard line.bbox.width > 0 else { return nil }
        return line.bbox.width / CGFloat(n)
    }

    /// The cell width a line contributes to a run's verdict, or nil if it is not evidence:
    /// too short to measure, or its own words disagree by more than `maxWordVariation`.
    /// A line with no word-box measurement at all keeps the pre-measurement behaviour.
    static func vote(_ line: OCRLine) -> CGFloat? {
        if let v = line.cellVariation, v > maxWordVariation { return nil }
        return cellWidth(line)
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
    /// first voter to its last, and then absorbs the non-voting lines trailing it only while they sit
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
            while end < limit, vote(lines[end]) == nil, lines[end].bbox.minX >= minX - 0.5 * cell {
                end += 1
            }
            runs.append(start..<end)
        }

        func open(at i: Int, _ cw: CGFloat, _ minX: CGFloat) {
            start = i; lastVoter = i; widths = [cw]; voterMinX = [minX]
        }

        for (i, line) in lines.enumerated() {
            guard let cw = vote(line) else { continue }               // no evidence: may join, does not vote
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
        return render(s, runs: monospaceRuns(s))
    }

    /// The render half on its own, for a caller that already sorted the lines and already knows
    /// the runs. `lines` is taken as sorted and `runs` verbatim: nothing is re-sorted and nothing
    /// is re-detected, so a caller that rewrote the text of a run (the uncorrected second OCR
    /// pass) still gets the fences it asked for rather than a fresh verdict on different strings.
    public static func render(_ s: [OCRLine], runs: [Range<Int>]) -> [RenderedLine] {
        var out = s.enumerated().map { i, l in
            RenderedLine(n: i + 1, text: l.text, bbox: l.bbox, confidence: l.confidence, fenced: false)
        }
        for run in runs where run.lowerBound >= 0 && run.upperBound <= s.count {
            // Only voting lines set the cell width and the left edge; a non-voting line inside the
            // run that starts further left than the block would otherwise shift every indent right.
            var voting = run.compactMap { i in vote(s[i]).map { (i, $0) } }
            // A caller that asked for this run gets it fenced even if none of the lines it holds
            // now is evidence on its own: the second OCR pass rewrites a run's text, and the
            // verdict was taken once, on the first pass, deliberately.
            if voting.isEmpty { voting = run.compactMap { i in cellWidth(s[i]).map { (i, $0) } } }
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
