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
    /// When the validator rejects a hit, retry shorter prefixes of it that end just before a
    /// space, `-` or `.` (longest first) and still match the whole pattern. A greedy pattern
    /// can swallow a trailing number ("BE68 5390 0754 7034 2025-01-15"); without the retry
    /// the checksum fails on the longer string and the real value stays in the clear.
    public let retryShorter: Bool
    /// When true, only the first capture group that took part in the match is validated and
    /// replaced; the rest of the match (a key name, a separator) stays in the text.
    public let replacesCaptureGroup: Bool

    public init(name: String, pattern: String,
                options: NSRegularExpression.Options = [.caseInsensitive],
                validator: (@Sendable (String) -> Bool)? = nil,
                retryShorter: Bool = false,
                replacesCaptureGroup: Bool = false) {
        self.name = name; self.pattern = pattern; self.options = options; self.validator = validator
        self.retryShorter = retryShorter; self.replacesCaptureGroup = replacesCaptureGroup
    }

    /// Keywords that mark the value after them as a credential: `password=`, `api_key:`,
    /// `client_secret =`, `X-API-Key:`. Anything may come before the keyword (`DB_PASSWORD`,
    /// `AWS_SECRET_ACCESS_KEY`), but whatever follows it must start with `_`, `-` or `.`, so
    /// `tokenizer:` and `secretary:` are not cues. A bare `key` is not a keyword: `key: value`
    /// in YAML and `primary key: id` are far more common than a secret under that name.
    /// Sources: OWASP Logging Cheat Sheet "Data to exclude", gitleaks generic-api-key keywords,
    /// detect-secrets KeywordDetector denylist (URLs in the redaction research report).
    private static let secretKeywords =
        #"(?:pass(?:word|wd|phrase)?|pwd|secrets?|tokens?|credentials?|"#
        + #"(?:api|access|secret|private|account|client|master|signing|encryption|auth|app)[_\-.]?key|apikey|"#
        + #"session[_\-]?(?:id|token|key)|sessionid)"#

    /// Keys that contain a keyword but name a number or a kind, not a credential: usage
    /// counters (`input_tokens`, `cache_read_input_tokens`, `max_tokens`), `token_count`,
    /// `token_type`, `pass_rate`. The value after one of these is never treated as a secret.
    /// Keys that contain a keyword but name a number or a kind, not a credential. A usage
    /// counter ending in "tokens" (`input_tokens`, `cache_read_input_tokens`, `max_tokens`)...
    /// It sits after the keyword so it runs only on a keyword hit, not at every position.
    private static let excludedTokenCounter =
        #"(?<!(?:max|min|input|output|cache|total|prompt|completion|reasoning|context|num)[_\-]tokens)"#
    /// ...or a count or kind suffix after it (`token_count`, `token_type`, `pass_rate`).
    private static let excludedKeySuffix =
        #"(?<![_\-.](?:count|counts|type|types|rate|rates|limit|limits|usage|budget|total|totals|len|length|size|ratio|pct|percent|used|remaining))"#

    /// Password keys. A numeric value is a secret only after one of these (a PIN); after any
    /// other keyword a number is a count or a setting (`token_limit: 100000`).
    private static let passwordKeys = #"(?:pass(?:word|wd|phrase)?|pwd)"#

    /// Builds the SECRET pattern for a keyword assignment with the given separator class. It
    /// matches forward from the keyword and the value is a capture group (the rule sets
    /// `replacesCaptureGroup`), so the key name stays in the text. Matching forward, not with a
    /// lookbehind at every position, keeps a 100,000-character line fast.
    /// A quoted value runs to its closing quote, so `,` `;` `&` inside it are kept; only an
    /// unquoted value stops at them (query strings, argument lists).
    private static func assignment(_ separator: String) -> String {
        let key = secretKeywords + excludedTokenCounter + #"(?:[_\-.][\w\-.]{0,20})?"# + excludedKeySuffix
        let gap = #"["']?[ \t]{0,3}"# + separator + #"[ \t]{0,3}"#
        // A number is a value only after a password key. The lookbehind runs once per keyword hit.
        let numericOnlyAfterPassword = "(?:(?<=" + passwordKeys + gap + ")"
            + #"|(?!["']?[0-9][0-9.,_+\-]*(?:["'\s`;&]|$)))"#
        let value = #"(?:"([^"\r\n]{4,})"|'([^'\r\n]{4,})'|["']?([^\s"'`,;&]{4,}))"#
        return key + gap + numericOnlyAfterPassword + value
    }

    /// Ordered most specific first, so a key is not eaten by a looser rule. The validators are
    /// passed as non-capturing closures: an unapplied reference to a static method is not a
    /// `@Sendable` function value, even when the method is pure.
    public static let builtin: [Rule] = [
        // --- Provider keys with a fixed prefix. These are the lowest false-positive rules. ---
        Rule(name: "AWS_KEY",     pattern: #"\b(?:A3T[A-Z0-9]|AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[0-9A-Z]{16}\b"#, options: []),
        Rule(name: "GITHUB_PAT",  pattern: #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, options: []),
        Rule(name: "GITLAB_PAT",  pattern: #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#, options: []),
        // Anthropic keys (sk-ant-api03-, sk-ant-admin01-, sk-ant-oat01-) used to fall through to
        // OPENAI_KEY. This rule runs first so the label says whose key leaked.
        Rule(name: "ANTHROPIC_KEY", pattern: #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#, options: []),
        Rule(name: "OPENAI_KEY",  pattern: #"\bsk-(?:proj-|svcacct-|admin-|live-)?[A-Za-z0-9_\-]{20,}\b"#, options: []),
        // Stripe secret and restricted keys, live and test, plus webhook signing secrets.
        // Publishable keys (pk_) are public by design and are left alone.
        Rule(name: "STRIPE_KEY",  pattern: #"\b(?:sk|rk)_(?:live|test|prod)_[A-Za-z0-9]{20,}\b"#, options: []),
        Rule(name: "STRIPE_KEY",  pattern: #"\bwhsec_[A-Za-z0-9+/=]{24,}"#, options: []),
        // Webhook URLs carry their secret in the path. TOKEN skips anything with "://", so
        // without these rules the whole URL reached the model.
        Rule(name: "SLACK_WEBHOOK", pattern: #"https?://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_\-/]{20,}"#),
        Rule(name: "DISCORD_WEBHOOK", pattern: #"https?://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d{17,20}/[A-Za-z0-9_\-]{30,}"#),
        Rule(name: "SLACK_TOKEN", pattern: #"\b(?:xox[abposre]|xapp)-[A-Za-z0-9\-]{10,}\b"#, options: []),
        Rule(name: "NPM_TOKEN",   pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#, options: []),
        Rule(name: "PYPI_TOKEN",  pattern: #"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{30,}"#, options: []),
        Rule(name: "HF_TOKEN",    pattern: #"\bhf_[A-Za-z0-9]{30,}\b"#, options: []),
        // Tailscale auth, API and OAuth client keys: tskey-auth-<id>-<secret>, plus the older
        // dash-free form (tskey-abcdef1432341818 in the Tailscale auth-keys docs) and OAuth
        // access tokens (tskey-0123456789ABCDEF...).
        Rule(name: "TAILSCALE_KEY", pattern: #"\btskey-(?:[a-z]+-[A-Za-z0-9_]{6,}-[A-Za-z0-9_]{10,}|[A-Za-z0-9]{16,}\b)"#, options: []),
        // 1Password: service account tokens, the account Secret Key from an Emergency Kit, and
        // op:// secret references. A reference is not the secret, but it names the vault and
        // item that hold one. A reference with a space in a name must be quoted, so the
        // unquoted form stops at whitespace.
        Rule(name: "ONEPASSWORD_TOKEN", pattern: #"\bops_eyJ[A-Za-z0-9+/=_\-]{20,}"#, options: []),
        Rule(name: "ONEPASSWORD_SECRET_KEY",
             pattern: #"\bA3-[A-Z0-9]{6}-(?:[A-Z0-9]{11}|[A-Z0-9]{6}-[A-Z0-9]{5})-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b"#, options: []),
        Rule(name: "OP_REF",      pattern: #"\bop://[^\s"'`<>]+"#, options: []),
        Rule(name: "GOOGLE_API_KEY", pattern: #"\bAIza[0-9A-Za-z_\-]{35}(?![0-9A-Za-z_\-])"#, options: []),
        Rule(name: "GOOGLE_OAUTH_SECRET", pattern: #"\bGOCSPX-[A-Za-z0-9_\-]{28}(?![A-Za-z0-9_\-])"#, options: []),
        // Twilio API key SIDs. Only SK..., because the AC... account SID is an identifier.
        Rule(name: "TWILIO_KEY",  pattern: #"\bSK[0-9a-fA-F]{32}\b"#, options: []),
        // Microsoft Entra (Azure AD) client secrets: three characters, a digit, "Q~", then the
        // rest. The shape is gitleaks' azure-ad-client-secret rule.
        Rule(name: "AZURE_CLIENT_SECRET", pattern: #"(?<![A-Za-z0-9_~.\-])[A-Za-z0-9_~.]{3}\dQ~[A-Za-z0-9_~.\-]{31,34}(?![A-Za-z0-9_~.\-])"#, options: []),
        // HashiCorp Vault service, batch and recovery tokens (hvs., hvb., hvr.).
        Rule(name: "VAULT_TOKEN", pattern: #"\bhv[sbr]\.[A-Za-z0-9_\-]{90,}"#, options: []),
        Rule(name: "JWT",         pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, options: []),
        // PEM headers, plus the PGP armor header ("-----BEGIN PGP PRIVATE KEY BLOCK-----").
        Rule(name: "PRIVATE_KEY", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----"#, options: []),

        // --- Credentials identified by their position, not their shape. ---
        // user:password inside a URL (postgres://, mongodb+srv://, https://, redis://). Only
        // the credentials go; the scheme and host stay so the line still reads. Runs before
        // EMAIL, which would otherwise read "pass@host.com" as an address. The password may
        // hold "/" or "@": it runs lazily to the first "@" that is followed by a host and then
        // a port, path, query, space or end. A port after the colon ("localhost:3000/x@b.com")
        // is not a password.
        Rule(name: "URL_CREDS",
             pattern: #"(?<=://)[^\s:/@\[\]]+:(?!\d{1,5}(?:[/?#]|\s|$))[^\s?#]+?(?=@(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.\-]+)(?:[:/?#]|\s|$))"#),
        // `[ \t]+`, never `\s+`: a builtin that can cross a newline redacts a joined document
        // differently from the lines it was joined from, which changed the line count in the
        // `--json` line array and left the token in the clear there.
        Rule(name: "BEARER",      pattern: #"\bBearer[ \t]+[A-Za-z0-9._\-]{16,}"#),
        // HTTP Basic credentials: base64 of user:password. The validator decodes the match and
        // requires a colon, so the English word "basic" followed by a word never fires.
        Rule(name: "BASIC_AUTH",  pattern: #"\bBasic[ \t]+[A-Za-z0-9+/]{6,}={0,2}"#,
             validator: { Validators.basicAuth($0) }),
        // KEY=value and KEY: value lines (.env files, YAML, JSON, headers, query strings).
        // Only the value goes. The validator drops placeholders, code references such as
        // process.env.X, and values another rule already replaced.
        Rule(name: "SECRET",      pattern: assignment(#"(?:=>?|:=?)"#),
             validator: { Validators.secretValue($0) }, replacesCaptureGroup: true),

        // --- Personal data. ---
        // The domain must not be a @2x/@3x/@2.5x scale suffix on an image filename, so "CleanShot
        // 2026-09-12 at 10.22.33@2x.png" is not an address. The exclusion is anchored to image
        // extensions: me@2x.io and me@2.5x.io are addresses. Digit-only local parts are still addresses.
        // The local part starts only at the beginning of a run of local-part characters and is
        // bounded at 64 (RFC 5321), the domain at 253, so the engine never rescans a long run
        // from every word boundary (quadratic on "a.a.a..."). A leading-dot local part
        // (".foo@x.com", invalid under RFC 5322) is no longer matched.
        Rule(name: "EMAIL",       pattern: #"(?<![A-Za-z0-9._%+\-])\b[A-Za-z0-9._%+\-]{1,64}@(?!\d+(?:\.\d+)?x\.(?:png|jpe?g|gif|webp|heic|tiff?)\b)[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,63}\b"#),
        Rule(name: "SSN",         pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#, options: []),
        // Windows and Office product keys: five groups of five from the product-key alphabet
        // (no vowels, no 0, 1 or 5; N is allowed since Windows 8), which keeps UUID fragments
        // and words out.
        Rule(name: "PRODUCT_KEY", pattern: #"\b[BCDFGHJKMNPQRTVWXY2346789]{5}(?:-[BCDFGHJKMNPQRTVWXY2346789]{5}){4}\b"#, options: []),
        // IBAN: country, two check digits, then the BBAN in optional groups of four and a short
        // tail, which may hold letters (Malta "... AST0 01S"). ISO 13616 mod-97 must pass. A
        // swallowed currency code ("... 00 USD") or trailing number fails the checksum, and
        // retryShorter then drops it at the group boundary.
        Rule(name: "IBAN",        pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#, options: [],
             validator: { Validators.iban($0) }, retryShorter: true),
        Rule(name: "ROUTING",     pattern: #"\b\d{4}[ \-]?\d{4}[ \-]?\d\b"#, options: [], validator: { Validators.aba($0) }),
        Rule(name: "CARD",        pattern: #"\b\d(?:[ \-]?\d){12,18}\b"#, options: [], validator: { Validators.luhn($0) }),
        // Bare digit runs are build numbers, epochs, and elapsed nanoseconds far more often than
        // account numbers. Require a context cue within 20 characters: an "acct"/"account"/"a/c"/
        // "micr" word, or a ROUTING hit already redacted on the same line (MICR strip).
        // ICU allows lookbehind with a bounded maximum length, which {0,20} is.
        // The cheap digit checks run first, so the cue lookbehind only runs where a digit run starts.
        Rule(name: "BANK_ACCT",   pattern: #"(?<!\d)(?=\d{8})(?<=(?:\b(?:acct|account|a/c|micr)\b|\[ROUTING\])[^\n\d]{0,20})\d{8,17}(?![\w\-/])"#),
        Rule(name: "PHONE",       pattern: #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, options: []),
        // International numbers in E.164 style ("+44 7911 123456", "+33 1 42 68 53 00"). The
        // leading + is required; the validator wants 8 to 15 digits (the E.164 maximum), at least
        // one separator, and no date or thousands shape. retryShorter drops a trailing number
        // ("+44 7911 123456 2024").
        Rule(name: "PHONE",       pattern: #"(?<![\w+])\+[1-9]\d{0,2}(?:[ \-.]?\(?\d{1,4}\)?){2,5}(?!\d)"#, options: [],
             validator: { Validators.internationalPhone($0) }, retryShorter: true),
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
