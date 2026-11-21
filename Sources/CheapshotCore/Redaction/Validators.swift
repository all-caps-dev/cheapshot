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
    private static let referenceShapes = [
        #"\[[A-Z0-9_]+\].*"#,                  // already replaced by a more specific rule
        #"\$\{[^}]*\}"#,                       // ${DB_PASSWORD}
        #"\{\{.*\}\}"#,                        // {{ secrets.TOKEN }}
        #"\$[A-Z_][A-Z0-9_]*"#,                // $DB_PASSWORD
        #"%[A-Z_][A-Z0-9_]*%"#,                 // %DB_PASSWORD% (Windows)
        #"%\([A-Za-z_]\w*\)s"#,                // %(password)s (Python format)
        #"<[^<>]+>"#,                           // <your-token>
        #"[*\u{2022}\u{25CF}xX#.\-_]+"#,         // masks: ****, ••••, xxxx, ####
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
    /// prefix-less secrets start at 4.66. 4.4 sits in the gap.
    public static func looksLikeSecret(_ s: String) -> Bool {
        if s.contains("://") { return false }   // URL
        if s.hasPrefix("/")  { return false }   // absolute path
        return entropy(s) >= 4.4
    }
}
