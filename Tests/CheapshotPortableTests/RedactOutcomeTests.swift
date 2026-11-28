// Swift. Tests for the redact engine's one decision, `RedactOutcome.decide` (CHE-56).
// Every test passes its policy explicitly, so flipping a pick in RedactDefaults moves only
// RedactDefaultsTests. The exhaustive tests walk every Bool, line counts 0 and 1, box counts
// 0 and 1, and all four policy combinations.
import XCTest
@testable import CheapshotPortable

/// Builds facts with every gate passed and a confirmed read, so each test changes only what it is about.
private func facts(checked: Int = 1, anyPass: Int = 1, retried: Bool = false, screenshotLike: Bool = true,
                   blank: Bool = false, boxes: Int = 0, settled: Bool = true, verify: Bool = true,
                   metadata: Bool = true) -> RedactFacts {
    RedactFacts(checkedLineCount: checked, anyPassLineCount: anyPass, retried: retried,
                screenshotLike: screenshotLike, blank: blank, boxCount: boxes, roundsSettled: settled,
                verifyClean: verify, metadataClean: metadata)
}

/// Every combination of facts the exhaustive tests walk: 6 Bools, and -1, 0, 1 for each count.
/// -1 is a count no caller should send; it must never write.
private let allFacts: [RedactFacts] = {
    var out: [RedactFacts] = []
    let bools = [false, true]
    let counts = [-1, 0, 1, 3]
    for checked in counts { for anyPass in counts { for boxes in counts {
        for retried in bools { for shot in bools { for blank in bools {
            for settled in bools { for verify in bools { for metadata in bools {
                out.append(facts(checked: checked, anyPass: anyPass, retried: retried, screenshotLike: shot,
                                 blank: blank, boxes: boxes, settled: settled, verify: verify, metadata: metadata))
            } } }
        } } }
    } } }
    return out
}()

/// Any count below zero. Such facts are malformed and are refused as unread.
private func hasNegativeCount(_ f: RedactFacts) -> Bool {
    f.checkedLineCount < 0 || f.anyPassLineCount < 0 || f.boxCount < 0
}

/// Row 1's shape: screenshot-like, nothing in the checked read, nothing painted.
private func unreadShape(_ f: RedactFacts) -> Bool {
    f.screenshotLike && f.checkedLineCount <= 0 && f.boxCount <= 0
}

/// Both named policies plus the other two combinations, so a policy switch cannot hide a hole.
private let allPolicies: [RedactPolicy] = [
    .redact, .mask,
    RedactPolicy(noText: .write, blankScreenshot: .write),
    RedactPolicy(noText: .refuse, blankScreenshot: .write),
    RedactPolicy(noText: .write, blankScreenshot: .refuse),
    RedactPolicy(noText: .refuse, blankScreenshot: .refuse),
]

final class RedactOutcomeTests: XCTestCase {
    let writeAll = RedactPolicy(noText: .write, blankScreenshot: .write)
    let refuseAll = RedactPolicy(noText: .refuse, blankScreenshot: .refuse)

    /// The nine rows of the plan's table (section 3.3), first match wins, one case each.
    func testEveryRowOfTheTable() {
        // 1: screenshot-like, checked read empty, no box, not blank: unread. Gates passed, still refused.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0), policy: writeAll), .refused(.unread))
        // 1 also covers blank under a policy that refuses blank screenshots.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, blank: true), policy: refuseAll),
                       .refused(.unread))
        // 2: a photo with no text anywhere, and Q1 says refuse.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, screenshotLike: false), policy: refuseAll),
                       .refused(.noText))
        // 3, 4, 5: each gate on its own.
        XCTAssertEqual(RedactOutcome.decide(facts(settled: false), policy: writeAll), .refused(.unstableMask))
        XCTAssertEqual(RedactOutcome.decide(facts(verify: false), policy: writeAll), .refused(.verifyFailed))
        XCTAssertEqual(RedactOutcome.decide(facts(metadata: false), policy: writeAll), .refused(.metadataCheckFailed))
        // 6: row 1's shape, blank, and the policy allows blank screenshots.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, blank: true), policy: writeAll),
                       .written(.blank))
        // 6 needs zero OCR evidence anywhere: blank with lines seen by another pass is unread.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 3, blank: true), policy: .redact),
                       .refused(.unread), "blank does not override lines a pass saw")
        // Negative counts are malformed: refused as unread, even when every gate passed.
        XCTAssertEqual(RedactOutcome.decide(facts(boxes: -1), policy: writeAll), .refused(.unread))
        XCTAssertEqual(RedactOutcome.decide(facts(checked: -1), policy: writeAll), .refused(.unread))
        XCTAssertEqual(RedactOutcome.decide(facts(anyPass: -1, screenshotLike: false), policy: writeAll),
                       .refused(.unread))
        // 7: something was painted.
        XCTAssertEqual(RedactOutcome.decide(facts(boxes: 1), policy: writeAll), .written(.masked))
        // 8: a photo with no text anywhere, and Q1 says write.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, screenshotLike: false), policy: writeAll),
                       .written(.noText))
        // 9: text was read and none of it was risky.
        XCTAssertEqual(RedactOutcome.decide(facts(), policy: writeAll), .written(.noMatches))

        // First match wins: an earlier row beats a later one.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, settled: false), policy: writeAll),
                       .refused(.unread), "row 1 before row 3")
        XCTAssertEqual(RedactOutcome.decide(facts(settled: false, verify: false, metadata: false), policy: writeAll),
                       .refused(.unstableMask), "row 3 before rows 4 and 5")
        XCTAssertEqual(RedactOutcome.decide(facts(verify: false, metadata: false), policy: writeAll),
                       .refused(.verifyFailed), "row 4 before row 5")
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, blank: true, metadata: false),
                                            policy: writeAll),
                       .refused(.metadataCheckFailed), "a blank screenshot still needs every gate")

        // status and reason are the strings the CLI prints.
        XCTAssertEqual(RedactOutcome.written(.noMatches).status, "written")
        XCTAssertEqual(RedactOutcome.written(.noMatches).reason, "no_matches")
        XCTAssertEqual(RedactOutcome.refused(.metadataCheckFailed).status, "refused")
        XCTAssertEqual(RedactOutcome.refused(.metadataCheckFailed).reason, "metadata_check_failed")
        XCTAssertTrue(RedactOutcome.written(.blank).isWritable)
        XCTAssertFalse(RedactOutcome.refused(.unread).isWritable)
    }

    /// T4 and M5: no input, under any policy, gives a writable outcome unless the re-read settled,
    /// verify passed and the metadata check passed. Covers no_text and blank, which wrote early before.
    func testNoWritableOutcomeWithoutAllThreeGates() {
        var writable = 0
        for policy in allPolicies {
            for f in allFacts {
                let outcome = RedactOutcome.decide(f, policy: policy)
                if outcome.isWritable {
                    writable += 1
                    XCTAssertTrue(f.roundsSettled && f.verifyClean && f.metadataClean,
                                  "\(outcome) written without every gate: \(f), \(policy)")
                }
            }
        }
        XCTAssertGreaterThan(writable, 0, "the walk must reach writable outcomes, or it proves nothing")
    }

    /// M6: a screenshot-like image whose checked read is empty, with no box, is never writable unless it
    /// is blank, no pass saw any line, and the policy writes blank screenshots. Any negative count is
    /// refused as unread too, whatever the other facts and the policy say.
    func testNoCombinationWritesAnUnreadScreenshot() {
        var seen = 0, contradicted = 0, negative = 0
        for policy in allPolicies {
            for f in allFacts {
                let outcome = RedactOutcome.decide(f, policy: policy)
                if hasNegativeCount(f) {
                    negative += 1
                    XCTAssertEqual(outcome, .refused(.unread), "negative count: \(f), \(policy)")
                    continue
                }
                guard unreadShape(f) else { continue }
                if !f.blank {
                    seen += 1
                    XCTAssertEqual(outcome, .refused(.unread), "\(f), \(policy)")
                }
                // Blank never overrides lines that some pass saw (review item 1).
                if f.anyPassLineCount > 0 {
                    contradicted += 1
                    XCTAssertEqual(outcome, .refused(.unread), "blank with lines seen: \(f), \(policy)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 0)
        XCTAssertGreaterThan(contradicted, 0)
        XCTAssertGreaterThan(negative, 0)
    }

    /// The six MaskGateTests cases (CheapshotCoreTests, #29), same expectations, through the mask policy.
    /// `status: .ok` is a checked read with lines; `.empty` is none. Gates are passed, so "not refused"
    /// means writable.
    func testMaskPolicyKeepsTheCHE24Gate() {
        let mask = RedactPolicy.mask
        func refusesBlank(screenshotLike: Bool, ok: Bool, boxes: Int, anyPass: Int = 0) -> Bool {
            let f = facts(checked: ok ? 2 : 0, anyPass: ok ? 2 : anyPass, screenshotLike: screenshotLike, boxes: boxes)
            let outcome = RedactOutcome.decide(f, policy: mask)
            if outcome == .refused(.unread) { return true }
            XCTAssertTrue(outcome.isWritable, "\(outcome) for \(f)")
            return false
        }
        // 1. Screenshot-like, checked read empty after the retry, nothing painted: refuse.
        XCTAssertTrue(refusesBlank(screenshotLike: true, ok: false, boxes: 0))
        // 2. Faint text: checked read empty but boxes were painted: mask it.
        XCTAssertFalse(refusesBlank(screenshotLike: true, ok: false, boxes: 1))
        // 3. A photo is not gated.
        XCTAssertFalse(refusesBlank(screenshotLike: false, ok: false, boxes: 0))
        XCTAssertFalse(refusesBlank(screenshotLike: false, ok: true, boxes: 0))
        // 4. A confirmed read is never refused, boxes or not.
        XCTAssertFalse(refusesBlank(screenshotLike: true, ok: true, boxes: 0))
        XCTAssertFalse(refusesBlank(screenshotLike: true, ok: true, boxes: 1))
        // 5. Clean lines from later passes but zero boxes after a cold checked read: still refuse.
        XCTAssertTrue(refusesBlank(screenshotLike: true, ok: false, boxes: 0, anyPass: 3),
                      "the gate keys on the checked read and boxes, not on lines from other passes")
        // 6. The refusal is unread, never a claim that there was no text.
        let refusal = RedactOutcome.decide(facts(checked: 0, anyPass: 0), policy: mask)
        XCTAssertEqual(refusal.reason, "unread")
        XCTAssertNotEqual(refusal, .refused(.noText))
    }

    /// Under a policy that refuses blank screenshots, the whole unread shape (every retried, line count,
    /// blank and gate combination) is refused as unread, and `.written(.blank)` never comes out at all.
    func testBlankNeverWritesUnderMaskPolicy() {
        var shapes = 0
        for policy in allPolicies where policy.blankScreenshot == .refuse {
            for f in allFacts {
                let outcome = RedactOutcome.decide(f, policy: policy)
                XCTAssertNotEqual(outcome, .written(.blank), "\(f), \(policy)")
                if unreadShape(f) {
                    shapes += 1
                    XCTAssertEqual(outcome, .refused(.unread), "\(f), \(policy)")
                }
            }
        }
        XCTAssertGreaterThan(shapes, 0)
        // And the mask policy is one of them.
        XCTAssertEqual(RedactPolicy.mask.blankScreenshot, .refuse)
    }

    /// Q1: a photo where no pass saw text and nothing was painted follows `policy.noText`.
    func testNoTextFollowsThePolicy() {
        let photo = facts(checked: 0, anyPass: 0, screenshotLike: false)
        XCTAssertEqual(RedactOutcome.decide(photo, policy: RedactPolicy(noText: .write, blankScreenshot: .refuse)),
                       .written(.noText))
        XCTAssertEqual(RedactOutcome.decide(photo, policy: RedactPolicy(noText: .refuse, blankScreenshot: .write)),
                       .refused(.noText))
        // A photo where some pass saw lines is not no_text under either value.
        let read = facts(checked: 0, anyPass: 1, screenshotLike: false)
        XCTAssertEqual(RedactOutcome.decide(read, policy: refuseAll), .written(.noMatches))
        // Nor is a photo that had something painted.
        XCTAssertEqual(RedactOutcome.decide(facts(checked: 0, anyPass: 0, screenshotLike: false, boxes: 1),
                                            policy: refuseAll), .written(.masked))
    }

    /// Rule 2: the only early return can only refuse. `preflight` returns rows 1 and 2 and nothing else,
    /// and whenever it refuses, `decide` refuses with the same reason.
    func testPreflightOnlyEverRefuses() {
        var refusals = 0
        for policy in allPolicies {
            for f in allFacts {
                let decided = RedactOutcome.decide(f, policy: policy)
                if let early = RedactOutcome.preflight(f, policy: policy) {
                    refusals += 1
                    XCTAssertTrue(early == .unread || early == .noText, "preflight returned \(early)")
                    XCTAssertEqual(decided, .refused(early), "\(f), \(policy)")
                } else {
                    XCTAssertNotEqual(decided, .refused(.unread), "row 1 must be in preflight: \(f), \(policy)")
                    XCTAssertNotEqual(decided, .refused(.noText), "row 2 must be in preflight: \(f), \(policy)")
                }
            }
        }
        XCTAssertGreaterThan(refusals, 0)
    }
}
