// Swift. The redact engine's one decision (CHE-56): given what OCR, the re-read, verify and the
// metadata check found, is a copy written or refused, and why. Pure and total, so every input can be
// tested without Vision. Foundation only: this file must compile on Windows.
import Foundation

/// Why a copy was written. The raw values are what the CLI prints.
public enum WrittenReason: String, Equatable, CaseIterable, Sendable {
    case masked, noMatches = "no_matches", noText = "no_text", blank
}

/// Why a copy was refused. The raw values are what the CLI prints.
public enum RefusedReason: String, Equatable, CaseIterable, Sendable {
    case unread, unstableMask = "unstable_mask", verifyFailed = "verify_failed"
    case metadataCheckFailed = "metadata_check_failed", noText = "no_text"   // noText only when Q1 is .refuse
}

/// Everything the decision reads. A struct, not nine positional arguments, so two Bools cannot be swapped.
public struct RedactFacts: Equatable, Sendable {
    /// Lines in the checked layout read at the floor, after its retry.
    public var checkedLineCount: Int
    /// Most lines any confidence-0 pass saw, re-reads of the output included.
    public var anyPassLineCount: Int
    public var retried: Bool
    public var screenshotLike: Bool
    /// BlankCheck result; false when it was not run.
    public var blank: Bool
    public var boxCount: Int
    /// False until a re-read of the encoded bytes found nothing new.
    public var roundsSettled: Bool
    /// False until Verify said .clean for the exact bytes returned.
    public var verifyClean: Bool
    /// False until the encoder's allowlist check passed for those bytes.
    public var metadataClean: Bool

    // Every field is required: there is no default that could quietly pass a gate.
    public init(checkedLineCount: Int, anyPassLineCount: Int, retried: Bool, screenshotLike: Bool, blank: Bool,
                boxCount: Int, roundsSettled: Bool, verifyClean: Bool, metadataClean: Bool) {
        self.checkedLineCount = checkedLineCount
        self.anyPassLineCount = anyPassLineCount
        self.retried = retried
        self.screenshotLike = screenshotLike
        self.blank = blank
        self.boxCount = boxCount
        self.roundsSettled = roundsSettled
        self.verifyClean = verifyClean
        self.metadataClean = metadataClean
    }
}

public enum RedactOutcome: Equatable, Sendable {
    case written(WrittenReason)
    case refused(RefusedReason)

    public var isWritable: Bool {
        if case .written = self { return true }
        return false
    }

    /// "written" or "refused".
    public var status: String { isWritable ? "written" : "refused" }

    /// The reason's printed name, such as "no_matches" or "verify_failed".
    public var reason: String {
        switch self {
        case .written(let r): return r.rawValue
        case .refused(let r): return r.rawValue
        }
    }

    /// Row 1's shape: a screenshot-like image whose checked read is empty and where nothing was
    /// painted. This is #29's gate: it keys on the checked read and on boxes, never on lines that
    /// other passes saw, so a cold checked read followed by clean lines elsewhere still counts.
    private static func unreadShape(_ f: RedactFacts) -> Bool {
        f.screenshotLike && f.checkedLineCount == 0 && f.boxCount == 0
    }

    /// Row 6's exception to row 1: the image is uniform and this caller allows blank screenshots.
    private static func blankAllowed(_ f: RedactFacts, policy: RedactPolicy) -> Bool {
        f.blank && policy.blankScreenshot == .write
    }

    /// A refusal that is already certain before anything is encoded (unread, or no_text under
    /// .refuse). nil otherwise. Rows 1 and 2 of the table; it can only ever refuse.
    public static func preflight(_ f: RedactFacts, policy: RedactPolicy) -> RefusedReason? {
        // Row 1.
        if unreadShape(f) && !blankAllowed(f, policy: policy) { return .unread }
        // Row 2: a photo where no pass saw text and nothing was painted, and Q1 says refuse.
        if !f.screenshotLike && f.anyPassLineCount == 0 && f.boxCount == 0 && policy.noText == .refuse {
            return .noText
        }
        return nil
    }

    /// The one decision. Total over every input. `.written` only when all three gate Bools are true.
    /// First match wins, in the order of the plan's table (section 3.3).
    public static func decide(_ f: RedactFacts, policy: RedactPolicy) -> RedactOutcome {
        // Rows 1 and 2: the refusals preflight already knows.
        if let early = preflight(f, policy: policy) { return .refused(early) }
        // Rows 3 to 5: the three gates. Every written reason below is reached only past all three,
        // including blank and no_text (trap T4: a no-text early return once skipped them).
        if !f.roundsSettled { return .refused(.unstableMask) }
        if !f.verifyClean { return .refused(.verifyFailed) }
        if !f.metadataClean { return .refused(.metadataCheckFailed) }
        // Row 6: only reachable when preflight let row 1's shape through, which needs blank and .write.
        if unreadShape(f) && blankAllowed(f, policy: policy) { return .written(.blank) }
        // Row 7.
        if f.boxCount > 0 { return .written(.masked) }
        // Row 8: a photo where no pass saw text (Q1 is .write, or row 2 would have refused).
        if !f.screenshotLike && f.anyPassLineCount == 0 { return .written(.noText) }
        // Row 9.
        return .written(.noMatches)
    }
}
