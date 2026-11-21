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
        // Printable ASCII only: random base64 that happens to decode is mostly control bytes.
        return decoded.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// True when the number of digits in `s` is inside `range`. Used for international phones.
    public static func digitCount(_ s: String, in range: ClosedRange<Int>) -> Bool {
        range.contains(s.filter(\.isNumber).count)
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

    /// SECRET's veto. A keyword cue (`password=`) is strong evidence by itself, so the bar is
    /// low: at least 6 characters, and a letters-only value needs 10 so prose such as
    /// "password: forgotten" survives. gitleaks' generic-api-key uses the same idea, a keyword
    /// plus a minimum length plus a letters-only allowlist.
    public static func secretValue(_ s: String) -> Bool {
        guard s.count >= 6 else { return false }
        let lower = s.lowercased()
        // Already replaced by a more specific rule, an environment or template reference, or a mask.
        if let first = s.first, "[$<{%*#\u{2022}\u{25CF}".contains(first) { return false }
        if Set(s).count == 1 { return false }                         // xxxxxx, ------
        if placeholderValues.contains(lower) { return false }
        if s.contains("://") || s.hasPrefix("/") || s.hasPrefix("~/") { return false }   // URL or path
        if s.contains("(") || s.contains(")") { return false }        // function call in code
        if codeReferencePrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        if lower.hasPrefix("your") || lower.hasPrefix("<your") { return false }   // your_api_key_here
        if s.allSatisfy({ $0.isLetter }) { return s.count >= 10 }
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
