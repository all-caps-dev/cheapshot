import XCTest
@testable import CheapshotCore

final class LayoutTests: XCTestCase {
    /// A monospace line: 8 px per character, 16 px tall, top-left origin.
    func mono(_ text: String, x: CGFloat, y: CGFloat, cell: CGFloat = 8) -> OCRLine {
        OCRLine(text: text, bbox: CGRect(x: x, y: y, width: cell * CGFloat(text.count), height: 16), confidence: 0.95)
    }

    func testCellWidth() {
        XCTAssertEqual(Layout.cellWidth(mono("abcdefgh", x: 0, y: 0)), 8)
        XCTAssertNil(Layout.cellWidth(mono("ab", x: 0, y: 0)), "lines under 4 chars do not vote")
        XCTAssertNil(Layout.cellWidth(OCRLine(text: "abcd", bbox: .zero, confidence: 1)))
    }

    func testMonospaceBlockGetsIndentationAndFence() {
        let lines = [
            mono("def main():", x: 100, y: 0),
            mono("x = compute()", x: 132, y: 16),      // 4 cells in
            mono("return x", x: 132, y: 32),
            mono("print(main())", x: 100, y: 48),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(r.map(\.text), ["def main():", "    x = compute()", "    return x", "print(main())"])
        XCTAssertEqual(r.map(\.n), [1, 2, 3, 4])
        XCTAssertTrue(r.allSatisfy(\.fenced))
        XCTAssertEqual(Layout.text(r), "```\ndef main():\n    x = compute()\n    return x\nprint(main())\n```")
    }

    func testProportionalLinesAreNotFencedOrIndented() {
        // Widths vary far more than 8% per character.
        let lines = [
            OCRLine(text: "iiiiiiiiii", bbox: CGRect(x: 0, y: 0, width: 30, height: 16), confidence: 1),
            OCRLine(text: "WWWWWWWWWW", bbox: CGRect(x: 40, y: 16, width: 140, height: 16), confidence: 1),
            OCRLine(text: "Hello there", bbox: CGRect(x: 80, y: 32, width: 70, height: 16), confidence: 1),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(Layout.monospaceRuns(lines), [])
        XCTAssertEqual(r.map(\.text), ["iiiiiiiiii", "WWWWWWWWWW", "Hello there"])
        XCTAssertFalse(r.contains(where: \.fenced))
        XCTAssertEqual(Layout.text(r), "iiiiiiiiii\nWWWWWWWWWW\nHello there")
    }

    func testMixedProseThenCode() {
        let lines = [
            OCRLine(text: "Here is the fix:", bbox: CGRect(x: 0, y: 0, width: 90, height: 16), confidence: 1),
            OCRLine(text: "Apply it and rerun.", bbox: CGRect(x: 0, y: 16, width: 140, height: 16), confidence: 1),
            mono("$ swift test", x: 0, y: 40),
            mono("Executed 3 tests", x: 0, y: 56),
            mono("with 0 failures", x: 0, y: 72),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(Layout.monospaceRuns(Layout.sorted(lines)), [2..<5])
        XCTAssertEqual(r.map(\.fenced), [false, false, true, true, true])
        XCTAssertEqual(Layout.text(r), "Here is the fix:\nApply it and rerun.\n```\n$ swift test\nExecuted 3 tests\nwith 0 failures\n```")
    }

    func testShortLinesJoinARunWithoutVoting() {
        let lines = [
            mono("import Foundation", x: 0, y: 0),
            mono("}", x: 0, y: 16),
            mono("func a() {}", x: 0, y: 32),
            mono("func b() {}", x: 0, y: 48),
        ]
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<4])
    }

    func testTwoVotingLinesAreNotARun() {
        let lines = [mono("func a() {}", x: 0, y: 0), mono("func b() {}", x: 0, y: 16)]
        XCTAssertEqual(Layout.monospaceRuns(lines), [])
    }

    func testSortedTopToBottomThenLeftToRight() {
        let lines = [
            mono("third", x: 0, y: 40),
            mono("first-right", x: 200, y: 2),
            mono("first-left", x: 0, y: 0),
            mono("second", x: 0, y: 20),
        ]
        XCTAssertEqual(Layout.sorted(lines).map(\.text), ["first-left", "first-right", "second", "third"])
        XCTAssertEqual(Layout.render(lines).map(\.n), [1, 2, 3, 4])
    }

    func testIndentIsCapped() {
        let lines = [mono("aaaa", x: 0, y: 0), mono("bbbb", x: 8 * 100, y: 16), mono("cccc", x: 0, y: 32)]
        XCTAssertEqual(Layout.render(lines)[1].text, String(repeating: " ", count: 40) + "bbbb")
    }

    func testEmpty() {
        XCTAssertEqual(Layout.render([]), [])
        XCTAssertEqual(Layout.text([]), "")
    }

    // MARK: - Fix round 1: proportional prose, sort order, trailing short lines

    /// A proportional line: `cell` is the font's measured average character width.
    func prose(_ cell: CGFloat, x: CGFloat, y: CGFloat, chars: Int = 64) -> OCRLine {
        OCRLine(text: String(repeating: "a", count: chars),
                bbox: CGRect(x: x, y: y, width: cell * CGFloat(chars), height: 16),
                confidence: 1)
    }

    /// Per-line cell widths measured with CoreText at 14pt in a 460pt column. Long prose lines
    /// converge on the font's average character width, so a loose tolerance fences paragraphs.
    func column(_ cells: [CGFloat], x: CGFloat = 0) -> [OCRLine] {
        cells.enumerated().map { i, c in prose(c, x: x, y: CGFloat(i) * 16) }
    }

    func testRealProseIsNotFenced() {
        for (font, cells) in [("Helvetica", [6.48, 6.22, 6.25, 6.03, 6.10] as [CGFloat]),
                              ("SF", [6.76, 6.55, 6.37, 6.59, 6.44, 6.17]),
                              ("Times", [5.93, 5.58, 5.70, 5.41, 5.72])] {
            let lines = column(cells)
            XCTAssertEqual(Layout.monospaceRuns(lines), [], "\(font) prose was read as a monospace run")
            XCTAssertFalse(Layout.text(Layout.render(lines)).contains("```"), "\(font) prose was fenced")
        }
    }

    func testStaggeredChatLinesAreNotIndented() {
        let cells: [CGFloat] = [6.11, 6.56, 6.20]
        let xs: [CGFloat] = [320, 360, 330]
        let lines = (0..<3).map { prose(cells[$0], x: xs[$0], y: CGFloat($0) * 16) }
        let r = Layout.render(lines)
        XCTAssertFalse(r.contains(where: \.fenced))
        XCTAssertFalse(r.contains { $0.text.hasPrefix(" ") }, "proportional UI text got spurious indentation")
        XCTAssertEqual(r.map(\.text), lines.map(\.text))
    }

    /// Deterministic shuffle, so a failure is reproducible.
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testSortedIsATotalOrderOnDenseInput() {
        // Rows 7 px apart with a 16 px line height: under half a line, which the old
        // tolerance-based comparator could not order transitively.
        let lines = (0..<200).map { i in
            OCRLine(text: "line \(i)",
                    bbox: CGRect(x: 1000 - CGFloat(i), y: CGFloat(i) * 7, width: 48, height: 16),
                    confidence: 1)
        }
        var outputs: [[CGFloat]] = []
        for seed in [1, 99, 123_456] as [UInt64] {
            var g = LCG(state: seed)
            let s = Layout.sorted(lines.shuffled(using: &g))
            let rows = s.map { Int(($0.bbox.minY / 16).rounded()) }
            XCTAssertEqual(rows, rows.sorted(), "quantized rows came back out of order for seed \(seed)")
            for (a, b) in zip(s, s.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.bbox.minY, a.bbox.minY - 16, "dropped more than one row backwards")
            }
            outputs.append(s.map(\.bbox.minY))
        }
        XCTAssertEqual(outputs[0], outputs[1], "sort order depends on input order")
        XCTAssertEqual(outputs[1], outputs[2], "sort order depends on input order")
    }

    /// Two genuine columns, 280 px of white space apart and offset by half a line. They are two
    /// panes, so they read column-major: the whole left column, then the whole right one. The
    /// row-quantization guard this case used to carry now lives in the overlapping variant below,
    /// where the spans really are one column.
    func testTwoColumnsOffsetByHalfALine() {
        let pitch: CGFloat = 18
        let a = [0, 18, 36, 54].map { y in
            OCRLine(text: "A\(y)", bbox: CGRect(x: 0, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        let b = [9, 27, 45].map { y in
            OCRLine(text: "B\(y)", bbox: CGRect(x: 400, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        let s = Layout.sorted(a + b)
        XCTAssertEqual(s.map(\.text), ["A0", "A18", "A36", "A54", "B9", "B27", "B45"],
                       "two disjoint columns did not read column-major")
    }

    /// The same fixture with the right block moved inside the left block's span: one column, so
    /// the rows interleave and the quantized total order still has to hold.
    func testOverlappingColumnsKeepRowQuantization() {
        let pitch: CGFloat = 18
        let a = [0, 18, 36, 54].map { y in
            OCRLine(text: "A\(y)", bbox: CGRect(x: 0, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        let b = [9, 27, 45].map { y in
            OCRLine(text: "B\(y)", bbox: CGRect(x: 100, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        XCTAssertEqual(Layout.columns(a + b).count, 1, "overlapping spans were split into columns")
        let s = Layout.sorted(a + b)
        let rows = s.map { Int(($0.bbox.minY / pitch).rounded()) }
        XCTAssertEqual(rows, rows.sorted(), "the two blocks did not group by quantized row")
        for i in s.indices {
            for j in s.indices where j > i {
                XCTAssertGreaterThanOrEqual(s[j].bbox.minY, s[i].bbox.minY - pitch,
                                            "line \(s[j].text) came more than one row above \(s[i].text)")
            }
        }
    }

    func testTrailingFarLeftLabelStaysOutOfTheRun() {
        let lines = [
            mono("let a = compute()", x: 200, y: 0),
            mono("let b = a + 1", x: 200, y: 16),
            mono("return b", x: 200, y: 32),
            mono("OK", x: 0, y: 48),
        ]
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<3])
        let r = Layout.render(lines)
        XCTAssertEqual(r.map(\.text), ["let a = compute()", "let b = a + 1", "return b", "OK"])
        XCTAssertEqual(r.map(\.fenced), [true, true, true, false])
    }

    func testTrailingAlignedBraceJoinsTheRun() {
        let lines = [
            mono("func f() {", x: 200, y: 0),
            mono("let x = 1", x: 200, y: 16),
            mono("return x", x: 200, y: 32),
            mono("}", x: 200, y: 48),
        ]
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<4])
        let r = Layout.render(lines)
        XCTAssertTrue(r.allSatisfy(\.fenced))
        XCTAssertEqual(r.map(\.text), ["func f() {", "let x = 1", "return x", "}"])
    }

    func testGutterDigitsDoNotShiftIndent() {
        var lines: [OCRLine] = []
        for (i, code) in ["let a = 1", "let b = 2", "let c = 3"].enumerated() {
            let y = CGFloat(i) * 16
            lines.append(mono("\(i + 1)", x: 0, y: y))
            lines.append(mono(code, x: 30, y: y))
        }
        let r = Layout.render(lines)
        let code = r.filter { $0.text.contains("let") }
        XCTAssertEqual(code.map(\.text), ["let a = 1", "let b = 2", "let c = 3"])
        XCTAssertFalse(r.contains { $0.text.hasPrefix(" ") }, "gutter digits shifted the block")
    }

    func testNonFiniteBoxDoesNotTrapTheSort() {
        let lines = [
            OCRLine(text: "nan box", bbox: CGRect(x: 0, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan), confidence: 0.9),
            mono("second line", x: 0, y: 0),
        ]
        XCTAssertEqual(Layout.render(lines).first?.text, "second line", "a non-finite row sorts last")
    }

    func testRenderWithExplicitRunsIgnoresDetection() {
        // Proportional-looking widths: monospaceRuns would find nothing here.
        let lines = [
            OCRLine(text: "a heading in prose", bbox: CGRect(x: 0, y: 0, width: 140, height: 16), confidence: 0.9),
            OCRLine(text: "func f() {", bbox: CGRect(x: 40, y: 16, width: 96, height: 16), confidence: 0.9),
            OCRLine(text: "return 1", bbox: CGRect(x: 56, y: 32, width: 61, height: 16), confidence: 0.9),
            OCRLine(text: "}", bbox: CGRect(x: 40, y: 48, width: 8, height: 16), confidence: 0.9),
            OCRLine(text: "more prose after it", bbox: CGRect(x: 0, y: 64, width: 210, height: 16), confidence: 0.9),
        ]
        XCTAssertEqual(Layout.monospaceRuns(lines), [], "precondition: detection finds no run here")
        let r = Layout.render(lines, runs: [1..<4])
        XCTAssertEqual(r.map(\.fenced), [false, true, true, true, false])
        XCTAssertEqual(r.map(\.n), [1, 2, 3, 4, 5])
        XCTAssertEqual(r[2].text, "  return 1", "indent still comes from the run's own cell width")
    }

    // MARK: - Task 10b: monospace evidence from Vision word boxes

    /// A line carrying word-box evidence: `cell` is both the box's width/count cell and the
    /// measured median per-word cell, `cv` the coefficient of variation across its words.
    func measured(_ text: String, x: CGFloat, y: CGFloat, cell: CGFloat = 8, cv: CGFloat) -> OCRLine {
        OCRLine(text: text, bbox: CGRect(x: x, y: y, width: cell * CGFloat(text.count), height: 16),
                confidence: 0.95, cellWidth: cell, cellVariation: cv)
    }

    func testWordVariationVetoesAVote() {
        let text = String(repeating: "a", count: 20)
        func varying(_ cvs: [CGFloat]) -> [OCRLine] {
            cvs.enumerated().map { i, cv in measured(text, x: 0, y: CGFloat(i) * 16, cv: cv) }
        }
        XCTAssertEqual(Layout.monospaceRuns(varying([0.02, 0.20, 0.02])), [],
                       "a line whose words vary too much must not vote, leaving two voters")
        XCTAssertEqual(Layout.monospaceRuns(varying([0.02, 0.05, 0.02])), [0..<3])
    }

    func testCellWidthFieldWins() {
        let text = String(repeating: "a", count: 20)
        let box = CGRect(x: 0, y: 0, width: 200, height: 16)
        XCTAssertEqual(Layout.cellWidth(OCRLine(text: text, bbox: box, confidence: 1, cellWidth: 8.0)), 8.0,
                       "the measured per-word cell beats the naive width/count estimate")
        XCTAssertEqual(Layout.cellWidth(OCRLine(text: text, bbox: box, confidence: 1)), 10)
        XCTAssertNil(Layout.cellWidth(OCRLine(text: "ab", bbox: box, confidence: 1, cellWidth: 8.0)),
                     "lines under 4 chars still do not vote")
    }

    func testProseWithHighVariationNeverFences() {
        // Naive cells within 1.3% of each other: tight enough for any tolerance on its own.
        let cells: [CGFloat] = [6.40, 6.44, 6.48, 6.45, 6.42]
        let cvs: [CGFloat] = [0.12, 0.15, 0.18, 0.13, 0.16]
        let text = String(repeating: "a", count: 60)
        let lines: [OCRLine] = (0..<5).map { (i: Int) -> OCRLine in
            let y: CGFloat = CGFloat(i) * 16
            let w: CGFloat = cells[i] * 60
            let box = CGRect(x: CGFloat(0), y: y, width: w, height: CGFloat(16))
            return OCRLine(text: text, bbox: box, confidence: 1, cellWidth: cells[i], cellVariation: cvs[i])
        }
        XCTAssertEqual(Layout.monospaceRuns(lines), [], "proportional words must not form a run")
        XCTAssertFalse(Layout.text(Layout.render(lines)).contains("```"), "prose was fenced")
    }

    func testNilFieldsKeepOldBehaviour() {
        let lines = [
            mono("def main():", x: 100, y: 0),
            mono("x = compute()", x: 132, y: 16),      // 4 cells in
            mono("return x", x: 132, y: 32),
            mono("print(main())", x: 100, y: 48),
        ]
        XCTAssertTrue(lines.allSatisfy { $0.cellWidth == nil && $0.cellVariation == nil })
        let r = Layout.render(lines)
        XCTAssertEqual(r.map(\.text), ["def main():", "    x = compute()", "    return x", "print(main())"])
        XCTAssertTrue(r.allSatisfy(\.fenced))
        XCTAssertEqual(Layout.text(r), "```\ndef main():\n    x = compute()\n    return x\nprint(main())\n```")
    }

    // MARK: - Fix round 2: column-aware reading order

    /// A line with an explicit horizontal span, so a fixture can place panes precisely. Passing
    /// `cv` also gives the line word-box evidence, with the box's own width/count as the cell.
    func pane(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat, cv: CGFloat? = nil) -> OCRLine {
        OCRLine(text: text, bbox: CGRect(x: x, y: y, width: width, height: 16), confidence: 1,
                cellWidth: cv == nil ? nil : width / CGFloat(text.count), cellVariation: cv)
    }

    func testDisjointColumnsReadColumnMajor() {
        // Two panes 300 px apart. A's cell is 15 px, B's 20 px, so the two blocks are also two
        // separate runs once the order stops interleaving them.
        let a = (0..<4).map { i in pane(String(repeating: "a", count: 20), x: 0, width: 300, y: CGFloat(i) * 16) }
        let b = (0..<4).map { i in pane(String(repeating: "b", count: 15), x: 600, width: 300, y: CGFloat(i) * 16) }
        var interleaved: [OCRLine] = []
        for i in 0..<4 { interleaved.append(a[i]); interleaved.append(b[i]) }
        let s = Layout.sorted(interleaved)
        XCTAssertEqual(s.map { $0.bbox.minX }, [0, 0, 0, 0, 600, 600, 600, 600],
                       "columns did not read left to right, whole column first")
        XCTAssertEqual(s.map { $0.bbox.minY }, [0, 16, 32, 48, 0, 16, 32, 48],
                       "rows inside a column came back out of order")
        XCTAssertEqual(Layout.monospaceRuns(s), [0..<4, 4..<8])
    }

    func testOverlappingSpansKeepRowOrder() {
        // Chat bubbles: the right bubble starts inside the left bubble's span, so this is one
        // column and the transcript keeps its row order.
        let lines = [
            pane("left one", x: 0, width: 500, y: 0),
            pane("right one", x: 300, width: 500, y: 20),
            pane("left two", x: 0, width: 500, y: 40),
        ]
        XCTAssertEqual(Layout.columns(lines).count, 1, "overlapping bubbles split into columns")
        XCTAssertEqual(Layout.sorted(lines).map(\.text), ["left one", "right one", "left two"])
    }

    func testRaggedRightEdgeDoesNotSplitAPane() {
        let widths: [CGFloat] = [100, 400, 180, 320, 140]
        let lines = widths.enumerated().map { i, w in pane("line \(i)", x: 50, width: w, y: CGFloat(i) * 16) }
        XCTAssertEqual(Layout.columns(lines).count, 1, "a ragged right edge split one pane into columns")
        XCTAssertEqual(Layout.sorted(lines).map(\.text), lines.map(\.text))
    }

    func testThreePanesWithProseBetween() {
        // The shape of a real three-pane capture: code left, prose in the middle, code right.
        let a = (0..<5).map { i in pane(String(repeating: "a", count: 20), x: 60, width: 640, y: CGFloat(i) * 22, cv: 0.03) }
        let b = (0..<4).map { i in pane(String(repeating: "b", count: 40), x: 900, width: 500, y: CGFloat(i) * 22 + 8, cv: 0.15) }
        let c = (0..<4).map { i in pane(String(repeating: "c", count: 22), x: 1850, width: 550, y: CGFloat(i) * 22 + 4, cv: 0.04) }
        let s = Layout.sorted(a + b + c)
        XCTAssertEqual(s.map { $0.bbox.minX }, [60, 60, 60, 60, 60, 900, 900, 900, 900, 1850, 1850, 1850, 1850])
        XCTAssertEqual(Layout.monospaceRuns(s), [0..<5, 9..<13], "the middle prose pane was swept into a run")
        let text = Layout.text(Layout.render(s))
        XCTAssertEqual(text.components(separatedBy: "```").count - 1, 4, "expected exactly two fenced blocks")
    }

    /// A span group needs `minimumVotingLines` lines before it is a column of its own. One
    /// far-left status label beside a code pane is not a second column: it merges into the pane
    /// it sits nearest and keeps its place in the row order, which is what leaves the trailing
    /// absorb rule to decide whether it belongs to the run.
    func testLoneFarLeftLabelIsNotItsOwnColumn() {
        let lines = [
            mono("let a = compute()", x: 200, y: 0),
            mono("let b = a + 1", x: 200, y: 16),
            mono("let c = b * 2", x: 200, y: 32),
            mono("return c", x: 200, y: 48),
            mono("OK", x: 0, y: 64),
        ]
        XCTAssertEqual(Layout.columns(lines).count, 1, "a lone far-left label became its own column")
        XCTAssertEqual(Layout.sorted(lines).map(\.text),
                       ["let a = compute()", "let b = a + 1", "let c = b * 2", "return c", "OK"])
        XCTAssertEqual(Layout.monospaceRuns(Layout.sorted(lines)), [0..<4])
    }

    // MARK: - Fix round 2: the small-group merge, and interior passengers

    /// Two real panes with one stray line between them, closer to the right pane. The stray is
    /// too small to be a column of its own, so it merges into the nearest one and takes its place
    /// in that column's row order rather than opening a third column.
    func testStrayLineJoinsTheNearestColumn() {
        let left = (0..<3).map { i in pane("left \(i)", x: 0, width: 300, y: CGFloat(i) * 16) }
        let right = (0..<3).map { i in pane("right \(i)", x: 800, width: 300, y: CGFloat(i) * 16) }
        let stray = pane("stray", x: 600, width: 100, y: 16)      // 300 px from left, 100 from right
        let cols = Layout.columns(left + [stray] + right)
        XCTAssertEqual(cols.count, 2, "the stray opened a column of its own")
        XCTAssertEqual(cols[0].count, 3, "the stray was merged into the left column")
        XCTAssertEqual(cols[1].count, 4, "the stray did not reach the nearer right column")
        XCTAssertEqual(Layout.sorted(left + [stray] + right).map(\.text),
                       ["left 0", "left 1", "left 2", "right 0", "stray", "right 1", "right 2"],
                       "the stray did not land in the right column's row order")
    }

    /// A line whose span is not a number cannot be placed in any column. It rides with the last
    /// one and takes its row position there, and nothing traps on the way.
    func testNonFiniteSpanRidesWithTheLastColumn() {
        let left = (0..<3).map { i in pane("left \(i)", x: 0, width: 300, y: CGFloat(i) * 16) }
        let right = (0..<3).map { i in pane("right \(i)", x: 800, width: 300, y: CGFloat(i) * 16) }
        let nan = OCRLine(text: "nan box",
                          bbox: CGRect(x: 0, y: 48, width: CGFloat.nan, height: 16), confidence: 1)
        let lines = left + [nan] + right
        XCTAssertEqual(Layout.columns(lines).count, 2, "a non-finite span opened a column")
        XCTAssertEqual(Layout.columns(lines)[1].count, 4, "the non-finite line did not ride with the last column")
        XCTAssertEqual(Layout.sorted(lines).map(\.text).last, "nan box",
                       "a non-finite span did not take its row position in the last column")
        XCTAssertEqual(Layout.render(lines).count, 7)
    }

    /// A foreign pane's prose wedged between two voters is not a passenger. The run splits at it,
    /// and each side survives only where it still has `minimumVotingLines` voters of its own.
    func testForeignPaneLineSplitsTheRun() {
        func code(_ i: Int) -> OCRLine {
            pane(String(repeating: "a", count: 20), x: 0, width: 300, y: CGFloat(i) * 16)
        }
        var lines = (0..<3).map(code)
        lines.append(pane(String(repeating: "b", count: 40), x: 400, width: 500, y: 48, cv: 0.15))
        lines.append(contentsOf: (4..<7).map(code))
        XCTAssertNil(Layout.vote(lines[3]), "precondition: the foreign line does not vote")
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<3, 4..<7],
                       "a foreign pane's line rode inside the run as an interior passenger")
        XCTAssertEqual(Layout.render(lines, runs: Layout.monospaceRuns(lines)).map(\.fenced),
                       [true, true, true, false, true, true, true])
    }

    /// The interior check uses the run's whole voter span, not the part of it seen so far: a wide
    /// non-voter that precedes the run's widest voter stays in the run.
    func testWideNonVoterStaysInsideTheRunsFullSpan() {
        let lines = [
            pane(String(repeating: "a", count: 20), x: 0, width: 300, y: 0),     // cell 15
            pane(String(repeating: "a", count: 20), x: 0, width: 300, y: 16),
            pane("end", x: 0, width: 420, y: 32),                                // 3 chars: no vote
            pane(String(repeating: "a", count: 30), x: 0, width: 450, y: 48),    // cell 15, and wider
            pane(String(repeating: "a", count: 30), x: 0, width: 450, y: 64),
        ]
        XCTAssertNil(Layout.vote(lines[2]), "precondition: a 3-character line does not vote")
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<5],
                       "a non-voter wider than the voters before it was thrown out of its own run")
    }
}
