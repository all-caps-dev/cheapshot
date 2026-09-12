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
    /// How far apart two horizontal spans must sit, in median line heights, before they are two
    /// columns rather than one pane with a ragged right edge.
    public static let columnGap: CGFloat = 1.5
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

    /// The lines grouped into columns, each group already in reading order and the groups left to
    /// right: the whole reading order, as indices into the input.
    ///
    /// A screenshot is rarely one column. Ordering a whole frame by row interleaves an editor, a
    /// browser pane and a sidebar line by line, and `monospaceRuns` only sees consecutive indices,
    /// so a real code block never gets three voters in a row while unrelated panes get swept into
    /// the same run. Columns are the lines' horizontal spans, merged where they overlap at all or
    /// sit closer than `columnGap` line heights apart, so a ragged right edge stays one pane and
    /// chat bubbles that overlap horizontally stay one transcript in row order.
    ///
    /// A span group is only a column once `minimumVotingLines` lines agree on it. A far-left "OK"
    /// status label, one lone indented line or a single right-aligned word is not a pane: it
    /// merges into the column nearest it horizontally and keeps its place in that column's row
    /// order. Fewer than two real columns means the frame is one column, and then the order is
    /// exactly the old whole-frame row sort.
    static func columns(_ lines: [OCRLine]) -> [[Int]] {
        guard !lines.isEmpty else { return [] }
        let gap = columnGap * rowPitch(lines)
        // A non-finite box has no span to place with. Those lines ride along with the rightmost
        // column and take their row position there; a non-finite row parks at the end besides.
        var spans: [(i: Int, lo: CGFloat, hi: CGFloat)] = []
        var unplaced: [Int] = []
        for (i, l) in lines.enumerated() {
            let lo = l.bbox.minX, hi = l.bbox.maxX
            if lo.isFinite, hi.isFinite, hi >= lo { spans.append((i, lo, hi)) } else { unplaced.append(i) }
        }
        var groups: [(idx: [Int], lo: CGFloat, hi: CGFloat)] = []
        // Sorted by left edge, so `s.lo - last.hi` is the gap to the group so far; a negative
        // value is an overlap.
        for s in spans.sorted(by: { $0.lo != $1.lo ? $0.lo < $1.lo : $0.hi < $1.hi }) {
            if var last = groups.last, s.lo - last.hi < gap {
                last.idx.append(s.i); last.hi = max(last.hi, s.hi)
                groups[groups.count - 1] = last
            } else {
                groups.append(([s.i], s.lo, s.hi))
            }
        }
        let real = groups.indices.filter { groups[$0].idx.count >= minimumVotingLines }
        guard real.count >= 2 else { return [readingOrder(Array(lines.indices), in: lines)] }
        let isColumn = Set(real)
        var buckets: [[Int]] = real.map { groups[$0].idx }       // already left to right
        for (g, group) in groups.enumerated() where !isColumn.contains(g) {
            var best = 0
            var bestDistance = CGFloat.infinity
            for (k, c) in real.enumerated() {
                let d = max(0, max(groups[c].lo - group.hi, group.lo - groups[c].hi))
                if d < bestDistance { bestDistance = d; best = k }
            }
            buckets[best].append(contentsOf: group.idx)
        }
        buckets[buckets.count - 1].append(contentsOf: unplaced)
        return buckets.map { readingOrder($0, in: lines) }
    }

    /// Column-major: the columns left to right, each one in its own reading order.
    static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        columns(lines).flatMap { $0.map { lines[$0] } }
    }

    /// One column's indices, top to bottom then left to right. Rows are quantized to a multiple of
    /// that column's median line height first, so the comparison is a total order on
    /// `(row, minX, minY)`. Comparing raw `minY` against a tolerance is not transitive (a and b
    /// within half a line, b and c within half a line, a and c not), which lets the result depend
    /// on the input order: dense pages came back reversed and rows offset by half a line
    /// interleaved wrongly. Quantizing per column keeps a sidebar set in 11pt from being rowed off
    /// an editor's 14pt.
    static func readingOrder(_ idx: [Int], in lines: [OCRLine]) -> [Int] {
        let pitch = rowPitch(idx.map { lines[$0] })
        // `Int(_:)` traps on a non-finite value, so a NaN box would crash the sort. Park those
        // rows at the end instead.
        func row(_ y: CGFloat) -> Int {
            let r = (y / pitch).rounded()
            return r.isFinite ? Int(r) : Int.max
        }
        return idx.sorted { a, b in
            let (p, q) = (lines[a].bbox, lines[b].bbox)
            let ra = row(p.minY)
            let rb = row(q.minY)
            if ra != rb { return ra < rb }
            if p.minX != q.minX { return p.minX < q.minX }
            return p.minY < q.minY
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
    /// `monospaceTolerance`. A run needs at least `minimumVotingLines` voters and spans from its
    /// first voter to its last.
    ///
    /// Every non-voting line the run would hold, inside it or trailing it, has to sit horizontally
    /// inside the block on both edges, `minX - 0.5 * cell ... maxX + 0.5 * cell` over the run's
    /// whole voter span: an aligned closing brace is code, a far-left status label or gutter digit
    /// is not, and neither is a neighbouring pane's prose, which runs past the right edge of
    /// everything the run voted on. Letting one in would drag the run's left edge with it, or
    /// fence a whole other column. The span is the run's final one rather than the part of it seen
    /// so far, so a long line with too few measurable words to vote is not thrown out merely for
    /// preceding the widest voter. An interior line that fails splits the run at that line, and
    /// each side is then judged the same way on its own narrower span, so a run may split more
    /// than once; a side survives only while it still has `minimumVotingLines` voters.
    public static func monospaceRuns(_ lines: [OCRLine]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var voters: [(i: Int, cell: CGFloat, lo: CGFloat, hi: CGFloat)] = []

        /// One stretch of mutually tight voters, emitted as a run once every non-voter it would
        /// hold fits inside the voters' span. `limit` is the first index the run may not reach.
        func emit(_ v: ArraySlice<(i: Int, cell: CGFloat, lo: CGFloat, hi: CGFloat)>, upTo limit: Int) {
            guard v.count >= minimumVotingLines, let first = v.first, let last = v.last else { return }
            let cell = median(v.map(\.cell))
            let minX = v.map(\.lo).min() ?? 0
            let maxX = v.map(\.hi).max() ?? 0
            func inside(_ i: Int) -> Bool {
                lines[i].bbox.minX >= minX - 0.5 * cell && lines[i].bbox.maxX <= maxX + 0.5 * cell
            }
            for i in (first.i + 1)..<last.i where vote(lines[i]) == nil && !inside(i) {
                emit(v.prefix { $0.i < i }, upTo: i)                  // the prefix stops short of it
                emit(v.drop { $0.i < i }, upTo: limit)
                return
            }
            var end = last.i + 1
            while end < limit, vote(lines[end]) == nil, inside(end) { end += 1 }
            runs.append(first.i..<end)
        }

        for (i, line) in lines.enumerated() {
            guard let cell = vote(line) else { continue }             // no evidence: may join, does not vote
            let v = (i: i, cell: cell, lo: line.bbox.minX, hi: line.bbox.maxX)
            if voters.isEmpty {
                voters = [v]                                          // a run starts at its first voter
            } else if isTight(voters.map(\.cell) + [cell]) {
                voters.append(v)
            } else {
                emit(voters[...], upTo: i)
                voters = [v]
            }
        }
        emit(voters[...], upTo: lines.count)
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
