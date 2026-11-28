// Swift. The redact engine's four open questions (Q1 to Q4), one constant each, plus the fixed
// numbers the engine shares. Change a pick here and nowhere else; RedactDefaultsTests is the one
// test that moves with it. Foundation only: this file must compile on Windows.
import Foundation

/// Q1. What happens to an image where OCR found no text at all.
public enum NoTextPolicy: String, Equatable, Sendable { case write, refuse }

/// Q2. What happens when the output name already exists.
public enum ClashPolicy: String, Equatable, CaseIterable, Sendable { case suffix, skip, error }

/// Q3. How outputs are named inside `--out-dir`.
public enum OutDirNaming: String, Equatable, Sendable { case redactedSuffix, originalName, originalUnlessSameFolder }

/// Q4. What happens to a type the engine can read but not write (webp, heif, avif, jxl).
public enum UnwritableFormatPolicy: String, Equatable, Sendable { case writePNG, refuse }

public enum RedactDefaults {
    public static let noText: NoTextPolicy = .write                  // Q1, option A
    public static let onClash: ClashPolicy = .suffix                 // Q2, option A
    public static let outDirNaming: OutDirNaming = .redactedSuffix   // Q3, option A
    public static let webP: UnwritableFormatPolicy = .writePNG       // Q4, option A
    /// Added before the extension: `shot.png` becomes `shot-redacted.png`.
    public static let marker = "-redacted"
    /// The highest clash counter tried (`shot-redacted-999.png`) before giving up.
    public static let maxSuffix = 999
    /// Lossy encode quality, and the range a caller may ask for.
    public static let quality = 0.9
    public static let qualityRange = 0.5...1.0
    /// The OCR confidence floor. Callers may raise it, never lower it.
    public static let minConfidence: Float = 0.3
}

/// What a caller lets the engine write when OCR found nothing. Two callers, two values:
/// `redact` writes a blank screenshot, `mask` refuses it (the #29 gate).
public struct RedactPolicy: Equatable, Sendable {
    /// A photo: not screenshot-like, and no pass saw text.
    public var noText: NoTextPolicy
    /// Screenshot-like, the checked read was empty, nothing was painted, and BlankCheck says uniform.
    public var blankScreenshot: NoTextPolicy

    public init(noText: NoTextPolicy, blankScreenshot: NoTextPolicy) {
        self.noText = noText
        self.blankScreenshot = blankScreenshot
    }

    /// The `redact` command: Q1 decides photos, blank screenshots are written.
    public static let redact = RedactPolicy(noText: RedactDefaults.noText, blankScreenshot: .write)
    /// The `mask` command: what #29 does today, so a blank screenshot is refused.
    public static let mask = RedactPolicy(noText: .write, blankScreenshot: .refuse)
}
