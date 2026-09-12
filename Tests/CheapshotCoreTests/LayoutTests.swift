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

    func testTwoColumnsOffsetByHalfALine() {
        let pitch: CGFloat = 18
        let a = [0, 18, 36, 54].map { y in
            OCRLine(text: "A\(y)", bbox: CGRect(x: 0, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        let b = [9, 27, 45].map { y in
            OCRLine(text: "B\(y)", bbox: CGRect(x: 400, y: CGFloat(y), width: 120, height: pitch), confidence: 1)
        }
        let s = Layout.sorted(a + b)
        let rows = s.map { Int(($0.bbox.minY / pitch).rounded()) }
        XCTAssertEqual(rows, rows.sorted(), "the two columns did not group by quantized row")
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
}
