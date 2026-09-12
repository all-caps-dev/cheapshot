import Foundation

/// One redaction rule. `validator` runs on each regex hit and can veto it.
public struct Rule {
    public let name: String
    public let pattern: String
    public let options: NSRegularExpression.Options
    public let validator: ((String) -> Bool)?

    public init(name: String, pattern: String,
                options: NSRegularExpression.Options = [.caseInsensitive],
                validator: ((String) -> Bool)? = nil) {
        self.name = name; self.pattern = pattern; self.options = options; self.validator = validator
    }

    /// Ordered most specific first, so a key is not eaten by a looser rule.
    public static let builtin: [Rule] = [
        Rule(name: "AWS_KEY",     pattern: #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#, options: []),
        Rule(name: "GITHUB_PAT",  pattern: #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, options: []),
        Rule(name: "OPENAI_KEY",  pattern: #"\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_\-]{20,}\b"#, options: []),
        Rule(name: "SLACK_TOKEN", pattern: #"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#, options: []),
        Rule(name: "JWT",         pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, options: []),
        Rule(name: "PRIVATE_KEY", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: []),
        Rule(name: "BEARER",      pattern: #"\bBearer\s+[A-Za-z0-9._\-]{16,}"#),
        Rule(name: "EMAIL",       pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        Rule(name: "SSN",         pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#, options: []),
        Rule(name: "ROUTING",     pattern: #"\b\d{4}[ \-]?\d{4}[ \-]?\d\b"#, options: [], validator: Validators.aba),
        Rule(name: "CARD",        pattern: #"\b\d(?:[ \-]?\d){12,18}\b"#, options: [], validator: Validators.luhn),
        Rule(name: "BANK_ACCT",   pattern: #"(?<![\w\-/])\d{8,}(?![\w\-/])"#, options: []),
        Rule(name: "PHONE",       pattern: #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, options: []),
        Rule(name: "TOKEN",       pattern: #"(?<![A-Za-z0-9_\-+/=.])(?=[A-Za-z0-9_\-+/=.]*[a-z])(?=[A-Za-z0-9_\-+/=.]*[A-Z])[A-Za-z0-9_\-+/=.]{20,}"#, options: [], validator: Validators.looksLikeSecret),
        Rule(name: "IPV4",        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#, options: []),
    ]
}
