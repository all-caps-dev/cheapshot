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
}
