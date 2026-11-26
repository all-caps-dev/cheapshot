import Foundation

/// URL_CREDS: `user:password` inside a URL (`postgres://`, `mongodb+srv://`, `redis://:pw@host`).
/// Only the credentials go; the scheme and host stay so the line still reads.
///
/// This is a hand-written scanner, not a regex, so the password and username have no length cap
/// and the run time is linear. An RDS IAM auth token in a connection URL is about 700
/// characters; the old regex capped the password at 256, because a lazy password with no cap
/// walks to the end of the line from every `://x:` (quadratic). The scanner instead
/// precomputes, in one backward pass, the next usable `@` for every position, so each `://`
/// costs only its scheme, its username and a table lookup. Usernames cannot hold `:` or `/`,
/// so two usernames never overlap and reading them is linear too.
///
/// Rules (``referencePattern`` is the same rules as a regex with caps, and the tests check that
/// both agree on short input):
/// 1. The username is any run of characters but whitespace, `:`, `/`, `@`, `[`, `]` (and the
///    URL's closer, rule 3), and may be empty (`redis://:pw@host`, `amqps://:pw@mq`).
/// 2. A port after the colon (`localhost:3000/x@b.com`, `"http://localhost:8080",`) is not a
///    password.
/// 3. A URL opens with a quote or bracket when the character before its scheme is `"`, `'`,
///    backtick, `<` or `(`. Its matching closer counts only when it is not escaped (`\"` in
///    JSON) and is followed by the end, whitespace or a delimiter (`, ; : . ! ) ] } > " '`,
///    backtick, `( [ { <`). So `(pg://u:p@ss)w0rd@host)` keeps `)w0rd` in the password, and two
///    quoted URLs in one JSON line are two hits.
/// 4. Strict end: the first `@` whose host is followed by a port (`:` and a digit), a path,
///    query or fragment, whitespace, the end, or the closer. The password runs up to
///    whitespace, `?`, `#` or the closer. A password may hold `@`, `,`, `)` or `:`
///    (`p@ss,w0rd@host`): the `@` before them is skipped because what follows it does not end
///    like a host.
/// 5. Tried in this order: strict end within the closer; strict end as a bare URL (no closer,
///    so the password can run past a raw closer); the last `@` followed by a host character
///    within the closer; the same as a bare URL. A credential is never kept just because its
///    host ended oddly (`pg://u:p@db, retry`).
public enum URLCreds {
    /// The openers rule 3 knows, each with its closer.
    static let closers: [(opener: UInt16, closer: UInt16)] = [
        (0x22, 0x22), (0x27, 0x27), (0x60, 0x60), (0x3C, 0x3E), (0x28, 0x29),   // " ' ` <> ()
    ]

    /// Characters after a closer that make it count (rule 3), besides whitespace and the end.
    private static let closerFollowers: Set<UInt16> = Set(",;:.!)]}>\"'`([{<".utf16)

    /// The scanner's rules as one regex, with caps (username 128, password 256, host 253,
    /// scheme 32). One branch per opener, each behind a lookbehind for that opener and the
    /// scheme, plus one branch for a URL with no opener. Kept as the rule's `pattern` and as the
    /// oracle for the differential test.
    public static let referencePattern: String = {
        func esc(_ c: UInt16) -> String {
            let ch = String(UnicodeScalar(UInt8(c)))
            return ch == "`" || ch == "\"" || ch == "'" || ch == "<" || ch == ">" ? ch : "\\" + ch
        }
        let followers = #"\s,;:.!)\]}>"'`(\[{<"#
        let host = #"@(?:\[[0-9A-Fa-f:.]{2,64}\]|[A-Za-z0-9.\-]{1,253})"#
        // Rule 4's ends; with a closer, the closer counts when a follower or the end comes next.
        func strictEnd(_ c: String?) -> String {
            #"(?::\d|[/?#]|\s|$"# + (c.map { "|" + $0 + "(?=$|[" + followers + "])" } ?? "") + ")"
        }
        // One password character: anything but whitespace, ? and #, and with a closer, the
        // closer only when it is escaped or not followed by a follower or the end.
        func pwChar(_ c: String?) -> String {
            guard let c else { return #"[^\s?#]"# }
            return #"(?:[^\s?#"# + c + "]|(?<=\\\\)" + c + "|" + c + "(?=[^" + followers + "]))"
        }
        let bareStrict = pwChar(nil) + "{1,256}?(?=" + host + strictEnd(nil) + ")"
        let bareLoose = pwChar(nil) + #"{1,256}(?=@[\[A-Za-z0-9.\-])"#
        func branch(_ closer: UInt16?) -> String {
            let c = closer.map(esc)
            let user = #"[^\s:/@\[\]"# + (c ?? "") + "]{0,128}:"
            let port = #"(?!\d{1,5}(?:[/?#]|\s|$"# + (c.map { "|" + $0 + "(?=$|[" + followers + "])" } ?? "") + "))"
            guard let c else { return user + port + "(?:" + bareStrict + "|" + bareLoose + ")" }
            let strict = pwChar(c) + "{1,256}?(?=" + host + strictEnd(c) + ")"
            let loose = pwChar(c) + #"{1,256}(?=@[\[A-Za-z0-9.\-])"#
            return user + port + "(?:" + [strict, bareStrict, loose, bareLoose].joined(separator: "|") + ")"
        }
        let openers = closers.map { esc($0.opener) }.joined()
        var parts = [#"(?<![\#(openers)][A-Za-z0-9+.\-]{0,32}://)(?<=://)"# + branch(nil)]
        for (o, c) in closers {
            parts.append("(?<=" + esc(o) + #"[A-Za-z0-9+.\-]{0,32}://)"# + branch(c))
        }
        return "(?:" + parts.joined(separator: "|") + ")"
    }()

    // UTF-16 code units for the ASCII characters the scanner looks at.
    private static let colon: UInt16 = 0x3A, slash: UInt16 = 0x2F, at: UInt16 = 0x40
    private static let lbracket: UInt16 = 0x5B, rbracket: UInt16 = 0x5D, backslash: UInt16 = 0x5C

    /// Rules 4 and 5 for one closer (nil: a bare URL), precomputed for every position.
    /// strictNext[i] is the first index >= i holding an "@" that is a strict end, with no
    /// password stop between i and it; looseLast[i] is the last index >= i, before the next
    /// stop, holding an "@" followed by a host character. -1 when there is none.
    private struct Tables {
        var strictNext: [Int32]
        var looseLast: [Int32]
    }

    /// Swift: one backward pass. Each host check reads at most 254 units and stops at the next
    /// non-host unit, so the pass is linear.
    private static func tables(_ u: [UInt16], closer: UInt16?) -> Tables {
        let n = u.count
        var t = Tables(strictNext: [Int32](repeating: -1, count: n + 1),
                       looseLast: [Int32](repeating: -1, count: n + 1))
        var i = n - 1
        while i >= 0 {
            if isPasswordStop(u[i]) || isCloser(u, i, closer) {
                t.strictNext[i] = -1; t.looseLast[i] = -1
            } else {
                let isAt = u[i] == at
                t.strictNext[i] = isAt && strictHost(u, i + 1, closer) ? Int32(i) : t.strictNext[i + 1]
                t.looseLast[i] = t.looseLast[i + 1] != -1 ? t.looseLast[i + 1]
                    : (isAt && i + 1 < n && (isHostChar(u[i + 1]) || u[i + 1] == lbracket) ? Int32(i) : -1)
            }
            i -= 1
        }
        return t
    }

    /// Swift: the NSRanges (UTF-16) of every `user:password` span, left to right, not overlapping.
    public static func ranges(in text: String) -> [NSRange] {
        let u = Array(text.utf16)
        let n = u.count
        // Fast path: most text has no "://" at all.
        guard n >= 5, hasSchemeSeparator(u) else { return [] }
        // Tables per closer, built the first time they are needed (at most six passes).
        var cache: [Int: Tables] = [:]
        func lookup(_ c: UInt16?) -> Tables {
            let key = c.map(Int.init) ?? -1
            if let t = cache[key] { return t }
            let t = tables(u, closer: c)
            cache[key] = t
            return t
        }
        var out: [NSRange] = []
        var lastEnd = 0
        var k = 0
        while k + 2 < n {
            if u[k] == colon && u[k + 1] == slash && u[k + 2] == slash, k + 3 >= lastEnd,
               let end = passwordEnd(u, from: k + 3, closerFor(u, schemeSeparatorAt: k), lookup) {
                out.append(NSRange(location: k + 3, length: end - (k + 3)))
                lastEnd = end
                k = max(k + 1, end - 2)
                continue
            }
            k += 1
        }
        return out
    }

    /// Swift: rule 3's closer for the URL whose "://" starts at `k`: the scheme is the run of up
    /// to 32 scheme characters before it, and the character before the scheme is the opener.
    private static func closerFor(_ u: [UInt16], schemeSeparatorAt k: Int) -> UInt16? {
        var j = k - 1
        while j >= 0, k - 1 - j < 33, isSchemeChar(u[j]) { j -= 1 }
        guard j >= 0, k - 1 - j <= 32 else { return nil }
        return closers.first { $0.opener == u[j] }?.closer
    }

    /// Swift: for userinfo starting at `start` (just after "://"), the index of the "@" that
    /// ends the password, or nil when this is not a credential.
    private static func passwordEnd(_ u: [UInt16], from start: Int, _ closer: UInt16?,
                                    _ lookup: (UInt16?) -> Tables) -> Int? {
        let n = u.count
        // Rule 1: username, then ":". A username holding the closer is refused.
        var k = start
        while k < n, isUserChar(u[k]), u[k] != closer { k += 1 }
        guard k < n, u[k] == colon else { return nil }
        // Rule 2: 1 to 5 digits, then a path, query, fragment, whitespace, the end or the
        // closer, is a port.
        var d = k + 1
        while d < n, d - k - 1 < 6, isDigit(u[d]) { d += 1 }
        let digits = d - k - 1
        if (1...5).contains(digits), d == n || isPortEnd(u[d]) || isCloser(u, d, closer) { return nil }
        // At least one password character.
        let p = k + 1
        guard p + 1 < n, !isPasswordStop(u[p]) else { return nil }
        let withCloser = closer.map { _ in lookup(closer) }
        let bare = lookup(nil)
        // Rule 5's order. A closer at p ends the closer's password before it starts.
        let closerOK = withCloser != nil && !isCloser(u, p, closer)
        if closerOK, let t = withCloser, t.strictNext[p + 1] >= 0 { return Int(t.strictNext[p + 1]) }
        if bare.strictNext[p + 1] >= 0 { return Int(bare.strictNext[p + 1]) }
        if closerOK, let t = withCloser, t.looseLast[p + 1] >= 0 { return Int(t.looseLast[p + 1]) }
        if bare.looseLast[p + 1] >= 0 { return Int(bare.looseLast[p + 1]) }
        return nil
    }

    /// Swift: rule 3, whether u[i] is the URL's closer: the closer character, not after a
    /// backslash, and followed by the end, whitespace or a delimiter.
    private static func isCloser(_ u: [UInt16], _ i: Int, _ closer: UInt16?) -> Bool {
        guard let closer, i < u.count, u[i] == closer else { return false }
        if i > 0 && u[i - 1] == backslash { return false }
        return i + 1 == u.count || isWhitespace(u[i + 1]) || closerFollowers.contains(u[i + 1])
    }

    private static func hasSchemeSeparator(_ u: [UInt16]) -> Bool {
        var k = 0
        while k + 2 < u.count {
            if u[k] == colon && u[k + 1] == slash && u[k + 2] == slash { return true }
            k += 1
        }
        return false
    }

    /// Rule 4's host: `[IPv6]` (2 to 64 of hex, ":" and ".") or 1 to 253 host characters, then
    /// a strict end.
    private static func strictHost(_ u: [UInt16], _ h: Int, _ closer: UInt16?) -> Bool {
        let n = u.count
        guard h < n else { return false }
        var k = h
        if u[h] == lbracket {
            k = h + 1
            while k < n, k - h - 1 <= 64, isHexColonDot(u[k]) { k += 1 }
            let count = k - h - 1
            guard (2...64).contains(count), k < n, u[k] == rbracket else { return false }
            return strictEnd(u, k + 1, closer)
        }
        while k < n, k - h <= 253, isHostChar(u[k]) { k += 1 }
        let length = k - h
        return (1...253).contains(length) && strictEnd(u, k, closer)
    }

    /// The end of a host under rule 4: end of text, whitespace, `/ ? #`, a port (":" then a
    /// digit), or the URL's closer.
    private static func strictEnd(_ u: [UInt16], _ k: Int, _ closer: UInt16?) -> Bool {
        guard k < u.count else { return true }
        let c = u[k]
        if c == colon { return k + 1 < u.count && isDigit(u[k + 1]) }
        if isCloser(u, k, closer) { return true }
        return c == 0x2F || c == 0x3F || c == 0x23 || isWhitespace(c)        // / ? # or space
    }

    // MARK: Character classes (UTF-16 code units; ICU's \s and \d for the non-ASCII cases)

    private static func isPasswordStop(_ c: UInt16) -> Bool {
        c == 0x3F || c == 0x23 || isWhitespace(c)                            // ? # or space
    }
    private static func isSchemeChar(_ c: UInt16) -> Bool {
        isHostChar(c) || c == 0x2B                                           // letters, digits, . - +
    }
    private static func isPortEnd(_ c: UInt16) -> Bool {
        c == 0x2F || c == 0x3F || c == 0x23 || isWhitespace(c)               // / ? # or space
    }
    private static func isUserChar(_ c: UInt16) -> Bool {
        !(c == colon || c == slash || c == at || c == lbracket || c == rbracket || isWhitespace(c))
    }
    private static func isHostChar(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x2D
    }
    private static func isHexColonDot(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) || c == colon || c == 0x2E
    }
    private static func isDigit(_ c: UInt16) -> Bool {
        if c < 0x80 { return c >= 0x30 && c <= 0x39 }
        guard let s = Unicode.Scalar(c) else { return false }                // a surrogate half
        return s.properties.numericType == .decimal
    }
    private static func isWhitespace(_ c: UInt16) -> Bool {
        if c < 0x80 { return c == 0x20 || (c >= 0x09 && c <= 0x0D) }
        guard let s = Unicode.Scalar(c) else { return false }
        return s.properties.isWhitespace
    }
}
