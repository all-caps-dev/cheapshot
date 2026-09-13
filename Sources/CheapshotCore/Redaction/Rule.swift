import Foundation

/// One redaction rule. `validator` runs on each regex hit and can veto it.
///
/// `Sendable`, so `Rule.builtin` is a legal global under complete strict concurrency checking:
/// every stored property is a value type and the validator is required to be `@Sendable`. The
/// `Validators` are static pure functions and qualify, but an unapplied reference to one is not
/// itself a `@Sendable` value, so `builtin` wraps each in a non-capturing closure.
public struct Rule: Sendable {
    public let name: String
    public let pattern: String
    public let options: NSRegularExpression.Options
    public let validator: (@Sendable (String) -> Bool)?

    public init(name: String, pattern: String,
                options: NSRegularExpression.Options = [.caseInsensitive],
                validator: (@Sendable (String) -> Bool)? = nil) {
        self.name = name; self.pattern = pattern; self.options = options; self.validator = validator
    }

    /// Ordered most specific first, so a key is not eaten by a looser rule. The validators are
    /// passed as non-capturing closures: an unapplied reference to a static method is not a
    /// `@Sendable` function value, even when the method is pure.
    public static let builtin: [Rule] = [
        Rule(name: "AWS_KEY",     pattern: #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#, options: []),
        Rule(name: "GITHUB_PAT",  pattern: #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, options: []),
        Rule(name: "OPENAI_KEY",  pattern: #"\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_\-]{20,}\b"#, options: []),
        Rule(name: "SLACK_TOKEN", pattern: #"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#, options: []),
        Rule(name: "JWT",         pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, options: []),
        Rule(name: "PRIVATE_KEY", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: []),
        // `[ \t]+`, never `\s+`: a builtin that can cross a newline redacts a joined document
        // differently from the lines it was joined from, which changed the line count in the
        // `--json` line array and left the token in the clear there.
        Rule(name: "BEARER",      pattern: #"\bBearer[ \t]+[A-Za-z0-9._\-]{16,}"#),
        // The domain must not be a @2x/@3x/@2.5x scale suffix on an image filename, so "CleanShot
        // 2026-09-12 at 10.22.33@2x.png" is not an address. The exclusion is anchored to image
        // extensions: me@2x.io and me@2.5x.io are addresses. Digit-only local parts are still addresses.
        Rule(name: "EMAIL",       pattern: #"\b[A-Za-z0-9._%+\-]+@(?!\d+(?:\.\d+)?x\.(?:png|jpe?g|gif|webp|heic|tiff?)\b)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        Rule(name: "SSN",         pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#, options: []),
        Rule(name: "ROUTING",     pattern: #"\b\d{4}[ \-]?\d{4}[ \-]?\d\b"#, options: [], validator: { Validators.aba($0) }),
        Rule(name: "CARD",        pattern: #"\b\d(?:[ \-]?\d){12,18}\b"#, options: [], validator: { Validators.luhn($0) }),
        // Bare digit runs are build numbers, epochs, and elapsed nanoseconds far more often than
        // account numbers. Require a context cue within 20 characters: an "acct"/"account"/"a/c"/
        // "micr" word, or a ROUTING hit already redacted on the same line (MICR strip).
        // ICU allows lookbehind with a bounded maximum length, which {0,20} is. IBANs are not
        // covered: the window cannot cross the check digits that follow the country code.
        Rule(name: "BANK_ACCT",   pattern: #"(?<=(?:\b(?:acct|account|a/c|micr)\b|\[ROUTING\])[^\n\d]{0,20})\d{8,17}(?![\w\-/])"#),
        Rule(name: "PHONE",       pattern: #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, options: []),
        Rule(name: "TOKEN",       pattern: #"(?<![A-Za-z0-9_\-+/=.])(?=[A-Za-z0-9_\-+/=.]*[a-z])(?=[A-Za-z0-9_\-+/=.]*[A-Z])[A-Za-z0-9_\-+/=.]{20,}"#, options: [], validator: { Validators.looksLikeSecret($0) }),
        Rule(name: "IPV4",        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#, options: []),
        // Vision reads the dots of a small-font address as single spaces or middle dots
        // ("100 102 55 50"). Same name so the counts merge. Octets are range-checked by the
        // regex; the validator refuses four single digits ("1 2 3 4"), which is prose or a
        // version, not an address. Accepted cost: a four-column row of numbers up to 255 with
        // five or more digits, such as top output or CSS shorthand, also redacts; a miss is worse.
        Rule(name: "IPV4",        pattern: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)[ \u00B7]){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#, options: [],
             validator: { $0.filter(\.isNumber).count > 4 }),
    ]
}
