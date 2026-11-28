import Foundation

public enum Validators {
    /// Luhn check so CARD only fires on a real card number.
    public static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// ABA routing numbers carry a checksum; validating it keeps ROUTING from eating every 9-digit number.
    public static func aba(_ s: String) -> Bool {
        let d = s.compactMap { $0.wholeNumberValue }
        guard d.count == 9 else { return false }
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }

    /// ISO 13616 IBAN check: 15 to 34 characters once spaces go, then move the first four to
    /// the end, turn letters into 10...35, and the number mod 97 must be 1. Computed digit by
    /// digit so a 34-character IBAN never overflows.
    public static func iban(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard (15...34).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged.uppercased() {
            guard let v = ch.isNumber ? ch.wholeNumberValue : Int(ch.asciiValue!) - 55 else { return false }
            // A letter is two digits (10...35); fold each digit in separately.
            for digit in String(v) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    /// HTTP Basic credentials are base64 of "user:password". Decoding and finding the colon
    /// is what separates them from the word "Basic" followed by an ordinary word.
    public static func basicAuth(_ s: String) -> Bool {
        guard let blob = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).last else { return false }
        var b64 = String(blob)
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8)
        else { return false }
        guard let colon = decoded.firstIndex(of: ":"), colon != decoded.startIndex else { return false }
        // No control characters (C0, DEL, C1): random base64 that happens to decode is mostly
        // control bytes. Any other UTF-8 is fine, so "jose:contraña" is caught.
        return decoded.unicodeScalars.allSatisfy { v in
            v.value >= 0x20 && v.value != 0x7F && !(0x80...0x9F).contains(v.value)
        }
    }

    /// True when the number of digits in `s` is inside `range`.
    public static func digitCount(_ s: String, in range: ClosedRange<Int>) -> Bool {
        range.contains(s.filter(\.isNumber).count)
    }

    /// International PHONE's veto: 8 to 15 digits, at least one separator after the "+", and
    /// not a date ("+2026-11-20") or a thousands-grouped number ("+12.345.678"). A bare "+"
    /// run ("+12345678") is a diff stat or a follower delta far more often than a phone.
    public static func internationalPhone(_ s: String) -> Bool {
        guard digitCount(s, in: 8...15) else { return false }
        guard s.dropFirst().contains(where: { " -.()".contains($0) }) else { return false }
        if fullMatch(#"\+\d{4}[\-./]\d{1,2}[\-./]\d{1,2}"#, s) { return false }
        if fullMatch(#"\+\d{1,3}(?:[.,]\d{3})+"#, s) { return false }
        return true
    }

    /// True when the whole of `s` matches `pattern`.
    static func fullMatch(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> Bool {
        var options: String.CompareOptions = [.regularExpression, .anchored]
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let r = s.range(of: pattern, options: options) else { return false }
        return r.upperBound == s.endIndex
    }

    /// Values that sit after a secret keyword but are not secrets: placeholders, masks, booleans,
    /// type names in docs, and code that reads the secret from somewhere else.
    private static let placeholderValues: Set<String> = [
        "true", "false", "null", "nil", "none", "undefined", "required", "optional", "string",
        "str", "bool", "boolean", "int", "integer", "number", "object", "example", "redacted",
        "hidden", "secret", "password", "token", "empty", "unset", "default", "changeit",
    ]
    private static let codeReferencePrefixes = [
        "process.env", "os.environ", "os.getenv", "env.", "env[", "config.", "settings.",
        "self.", "this.", "secrets.", "vars.", "inputs.", "import.meta",
    ]

    /// Whole-value shapes that point at a secret instead of being one. Each is a full match,
    /// so a real password that merely starts with "$" or "#", or holds "(", is still caught.
    /// Each must be valid ICU syntax: Apple's `String.range(of:options: .regularExpression)`
    /// tolerates some invalid escapes that NSRegularExpression (and so Windows Foundation)
    /// rejects, and a rejected pattern silently never matches (PR #23: `\u{2022}` made every
    /// mask such as `xxxx-xxxx` count as a secret on Windows). ValidatorsTests compiles them all.
    static let referenceShapes = [
        #"\[[A-Z0-9_]+\].*"#,                  // already replaced by a more specific rule
        #"\$\{[^}]*\}"#,                       // ${DB_PASSWORD}
        #"\{\{.*\}\}"#,                        // {{ secrets.TOKEN }}
        #"\$[A-Z_][A-Z0-9_]*"#,                // $DB_PASSWORD
        #"%[A-Z_][A-Z0-9_]*%"#,                 // %DB_PASSWORD% (Windows)
        #"%\([A-Za-z_]\w*\)s"#,                // %(password)s (Python format)
        #"<[^<>]+>"#,                           // <your-token>
        #"[*\x{2022}\x{25CF}xX#.\-_]+"#,         // masks: ****, ••••, xxxx, ####
    ]

    /// `name(...)` call syntax in code: `getToken()`, `os.getenv("X")`, `getSecret(name)`. The
    /// arguments must be empty or quoted, or the name must read as code (a ".", a "_" or a
    /// camelCase hump), so a password such as "Hunter2(prod)" is not taken for a call.
    static func looksLikeCall(_ t: String) -> Bool {
        guard fullMatch(#"[A-Za-z_][\w.:]*\(.*\)"#, t), let open = t.firstIndex(of: "(") else { return false }
        let name = t[..<open]
        let args = t[t.index(after: open)..<t.index(before: t.endIndex)]
        if args.isEmpty || args.first == "\"" || args.first == "'" { return true }
        return name.contains(".") || name.contains("_") || fullMatch(#".*[a-z][A-Z].*"#, String(name))
    }

    /// First segments that make a dotted, digit-free value read as a code path, not a passphrase.
    /// Short everyday words (`this`, `data`, `app`) are left out, since a miss costs more than a false
    /// hit. A few roots are still words (`request`, `settings`), so `request.denied.again` is kept.
    static let codePathRoots: Set<String> = [
        "args", "cfg", "config", "creds", "ctx", "env", "json", "kwargs", "options", "opts", "os",
        "params", "payload", "process", "props", "req", "res", "request", "resp", "response",
        "secrets", "settings",
    ]

    /// True when a dotted value starts with a code root (`process.env.DB_PASS`,
    /// `response.data.token`). A "_" or camelCase segment alone is not enough: `iLove.myDog` and
    /// `horse_battery.staple` are passphrases.
    static func looksLikeCodePath(_ t: String) -> Bool {
        guard let first = t.split(separator: ".").first else { return false }
        return codePathRoots.contains(first.lowercased())
    }

    /// A CSS class name such as `sk-cube-grid-container-wrapper`: lowercase words joined by
    /// hyphens, at least three of them, none longer than 12 letters.
    public static func looksLikeHyphenatedWords(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { $0.isASCII && $0.isLowercase } }
    }

    /// SECRET's veto. A keyword cue (`password=`) is strong evidence by itself, so the bar is
    /// low: at least 6 characters, and a letters-only value needs 10 so prose such as
    /// "password: forgotten" survives. gitleaks' generic-api-key uses the same idea, a keyword
    /// plus a minimum length plus a letters-only allowlist.
    public static func secretValue(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6 else { return false }
        let lower = t.lowercased()
        if Set(t).count == 1 { return false }                         // xxxxxx, ------
        if placeholderValues.contains(lower) { return false }
        if referenceShapes.contains(where: { fullMatch($0, t) }) { return false }
        if looksLikeCall(t) { return false }
        if t.contains("://") { return false }                         // URL
        // A path has a second "/" (/etc/secrets, ~/.ssh/key); "/x9Kq2..." alone is a password.
        if (t.hasPrefix("/") || t.hasPrefix("~/")) && t.dropFirst(2).contains("/") { return false }
        if codeReferencePrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        if fullMatch(#"your[a-z0-9_\-]*"#, lower) { return false }    // your_api_key_here
        // A dotted code path with no digit reads the secret from elsewhere: `response.data.token`.
        // It must also start with a code root such as `req` or `process`, so a dotted passphrase
        // such as `data.center.rocks` still redacts. Known gap, as on v0.5.0: the prefixes in
        // `codeReferencePrefixes` above (`this.`, `self.`, `config.`, `env.` and the rest) veto any
        // value that starts with them, so `this.is.my.password` is kept.
        if fullMatch(#"[a-z_][A-Za-z_]*(?:\.[A-Za-z_][A-Za-z_]*)+"#, t) && looksLikeCodePath(t) { return false }
        // A fraction or ratio is a count, not a PIN: `tests pass: 142/150`, `tokens: 123.4k/200k`.
        if fullMatch(#"\d+(?:\.\d+)?[kKmM]?/\d+(?:\.\d+)?[kKmM]?"#, t) { return false }
        // A quoted value may hold spaces; words of letters only are prose ("is required").
        if t.contains(" ") && t.split(separator: " ").allSatisfy({ $0.allSatisfy(\.isLetter) }) { return false }
        if t.allSatisfy({ $0.isLetter }) { return t.count >= 10 }
        return true
    }

    /// Shannon entropy, bits per character.
    public static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// TOKEN is the catch-all for secrets with no recognizable prefix. Its character class
    /// contains "/" and ".", so without a gate it swallows every absolute path and screenshot
    /// filename. Measured on real input: paths and CleanShot filenames top out at 4.14 bits/char,
    /// prefix-less secrets start at 4.66. 4.4 sits in the gap for 32 characters and up.
    ///
    /// Below 32 characters a fixed 4.4 is unreachable or nearly so (n characters carry at most
    /// log2(n) bits each: 4.32 at 20), so a 24-character random secret was caught 16% of the time.
    /// Short runs also pass ``looksLikeShortSecret``; the 4.4 gate stays as an OR so a random key
    /// v0.5.0 caught is not lost. It skips only a value with a method name after a dot (four or
    /// more lowercase letters, then a capital: `WKWebView.loadHTMLString2`), so a dotted random
    /// password (`Kx9.mQ2vB7nZmqvbR8tY1pL3sD6fH`) is still caught.
    public static func looksLikeSecret(_ s: String) -> Bool {
        if s.contains("://") { return false }   // URL
        if s.hasPrefix("/")  { return false }   // absolute path
        if s.count < 32 {
            let dottedCode = fullMatch(#".*\.[a-z]{4,}[A-Z].*"#, s)
            return (entropy(s) >= 4.4 && !dottedCode) || looksLikeShortSecret(s)
        }
        return entropy(s) >= 4.4
    }

    /// Base64 starts of image and key files. A short fragment of one in source code is data, not
    /// a credential: PNG, GIF, WebP, SVG, and the OpenSSH public key blob.
    private static let base64FilePrefixes = ["iVBORw0KGgo", "R0lGOD", "UklGR", "PHN2Zy", "AAAAC3NzaC1", "AAAAB3NzaC1"]

    /// The 20 to 31 character gate. The bar scales with length (0.84 of the log2(n) ceiling) and
    /// four shape checks keep code out. Calibrated with seeded random strings: about 91% of
    /// base62, base64 and base64url secrets at every length from 20 to 31 pass (was 0% at 20,
    /// 16% at 24), and none of a 50-item corpus of identifiers, filenames, versions and paths does.
    /// - a digit: camelCase identifiers rarely have one, random base62 of 20 almost always does
    /// - no ".": dotted names, filenames and versions (`com.apple.Safari.v17`, `Ubuntu-22.04`)
    /// - no lowercase run longer than 5: words (`iPhone15ProMaxSimulator` has "imulator")
    /// - no all-digit segment of 3+ between separators: dates and numbers (`CVE-2024-3094-x`)
    /// - the character class (lower, upper, digit, other) changes at 40% or more of positions:
    ///   random text changes about 62% of the time, camelCase about 20%
    static func looksLikeShortSecret(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 2, chars.contains(where: \.isNumber), !chars.contains(".") else { return false }
        if base64FilePrefixes.contains(where: { s.hasPrefix($0) }) { return false }
        // Longest run of lowercase ASCII letters.
        var run = 0, longest = 0
        for c in chars { run = (c.isASCII && c.isLowercase) ? run + 1 : 0; longest = max(longest, run) }
        if longest > 5 { return false }
        let segments = s.split(whereSeparator: { "-_/+=".contains($0) })
        if segments.contains(where: { $0.count >= 3 && $0.allSatisfy(\.isNumber) }) { return false }
        // Share of adjacent pairs whose character class differs.
        func kind(_ c: Character) -> Int { c.isLowercase ? 0 : c.isUppercase ? 1 : c.isNumber ? 2 : 3 }
        let changes = zip(chars, chars.dropFirst()).filter { kind($0) != kind($1) }.count
        if Double(changes) / Double(chars.count - 1) < 0.4 { return false }
        return entropy(s) >= 0.84 * log2(Double(chars.count))
    }
}
