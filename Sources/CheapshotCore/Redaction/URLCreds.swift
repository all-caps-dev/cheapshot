import Foundation

/// URL_CREDS: `user:password` inside a URL (`postgres://`, `mongodb+srv://`, `redis://:pw@host`).
/// Only the credentials go; the scheme and host stay so the line still reads.
///
/// This is a hand-written scanner, not a regex, so the password and username have no length cap
/// and the run time is linear. An RDS IAM auth token in a connection URL is about 700
/// characters; the old regex capped the password at 256, because a lazy password with no cap
/// walks to the end of the line from every `://x:` (quadratic). The scanner instead
/// precomputes, in backward passes, the next usable `@` for every position, so each `://`
/// costs only its scheme, its username and a table lookup. Usernames cannot hold `:` or `/`,
/// so two usernames never overlap and reading them is linear too. No credential crosses
/// whitespace, so the text is scanned one whitespace-free token at a time and the tables are
/// only as large as the longest token.
///
/// Rules (``referencePattern`` is the same rules as a regex with caps, and the tests check that
/// both agree on short input):
/// 1. The username is any run of characters but whitespace, `:`, `/`, `@`, `[`, `]` and a
///    stopping closer (rule 3), and may be empty (`redis://:pw@host`, `amqps://:pw@mq`).
/// 2. A port after the colon (`localhost:3000/x@b.com`, `"http://localhost:8080",`) is not a
///    password.
/// 3. A URL opens with a quote or bracket when the character before its scheme is `"`, `'`,
///    backtick, `<` or `(`. Its closer character is raw unless escaped (`\"` in JSON) or, for a
///    quote or backtick, doubled (`''` in SQL). A raw closer is real when the end, whitespace
///    or a delimiter follows (`, ; : . ! ) ] } > " '`, backtick, `( [ { <`). A real closer stops
///    the URL only when no later `@` followed by a host character can be reached without
///    crossing whitespace, `?`, `#`, `://`, or the start of another item (a raw quote for a
///    quoted URL, the opening bracket for a bracketed one). So `(pg://u:p@ss).w0rd@host/db)` keeps
///    `).w0rd` in the password, while two quoted URLs in one JSON line stay two hits.
/// 4. Strict end: the first `@` whose host is followed by a port (`:` and a digit), a path,
///    query or fragment, whitespace, the end, or a stopping closer. The password runs up to
///    whitespace, `?`, `#` or a stopping closer. A password may hold `@`, `,`, `)` or `:`
///    (`p@ss,w0rd@host`): the `@` before them is skipped because what follows it does not end
///    like a host.
/// 5. Otherwise the last `@` followed by a host character, within the same run, is used
///    (`pg://u:p@db, retry`). A credential is never kept just because its host ended oddly.
public enum URLCreds {
    /// The openers rule 3 knows, each with its closer.
    static let closers: [(opener: UInt16, closer: UInt16)] = [
        (0x22, 0x22), (0x27, 0x27), (0x60, 0x60), (0x3C, 0x3E), (0x28, 0x29),   // " ' ` <> ()
    ]

    /// Characters after a raw closer that make it real (rule 3), besides whitespace and the end.
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
        let bareEnd = #"(?::\d|[/?#]|\s|$"#
        func branch(_ closer: UInt16?) -> String {
            guard let closer else {
                let user = #"[^\s:/@\[\]]{0,128}:(?!\d{1,5}(?:[/?#]|\s|$))"#
                let strict = #"[^\s?#]{1,256}?(?="# + host + bareEnd + "))"
                let loose = #"[^\s?#]{1,256}(?=@[\[A-Za-z0-9.\-])"#
                return user + "(?:" + strict + "|" + loose + ")"
            }
            let c = esc(closer)
            let quote = isQuote(closer)
            let o = esc(closers.first { $0.closer == closer }!.opener)
            // A raw closer, consumed: not escaped, and for a quote not doubled.
            let raw = quote ? "(?<![\\\\" + c + "])" + c + "(?!" + c + ")" : "(?<!\\\\)" + c
            let real = raw + "(?=$|[" + followers + "])"
            // One character between a real closer and a later "@": no whitespace, ? or #, no
            // "://", and no raw quote (quoted URL) or opening bracket (bracketed URL).
            let notRaw = "(?<=\\\\)" + c + "|(?<=" + c + ")" + c + "|" + c + "(?=" + c + ")"
            let seg = quote ? #"(?!://)(?:[^\s?#"# + c + "]|" + notRaw + ")" : #"(?!://)[^\s?#"# + o + "]"
            let ext = "(?:" + seg + #")*?@[\[A-Za-z0-9.\-]"#
            let stop = real + "(?!" + ext + ")"
            let pwChar = #"(?:[^\s?#"# + c + "]|(?!" + stop + ")" + c + ")"
            let user = #"(?:[^\s:/@\[\]"# + c + "]|(?!" + stop + ")" + c + "){0,128}:"
            let port = #"(?!\d{1,5}(?:[/?#]|\s|$|"# + stop + "))"
            let strict = pwChar + "{1,256}?(?=" + host + bareEnd + "|" + stop + "))"
            let loose = pwChar + #"{1,256}(?=@[\[A-Za-z0-9.\-])"#
            return user + port + "(?:" + strict + "|" + loose + ")"
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

    /// One whitespace-free token and the tables for one closer (nil: a URL with no opener).
    /// stop[i]: rule 3, u[i] is a stopping closer. strictNext[i]: the first index >= i holding
    /// an "@" with a strict end, with no password stop between i and it. looseLast[i]: the last
    /// index >= i, before the next stop, holding an "@" followed by a host character. -1: none.
    private struct Tables {
        var stop: [Bool]
        var strictNext: [Int32]
        var looseLast: [Int32]
    }

    /// Swift: the backward passes for one closer. Each host check reads at most 254 units and
    /// stops at the next non-host unit, so every pass is linear.
    private static func tables(_ u: [UInt16], closer: UInt16?) -> Tables {
        let n = u.count
        var stop = [Bool](repeating: false, count: n + 1)
        if let closer {
            let opener = closers.first { $0.closer == closer }!.opener
            // ext: an "@" followed by a host character, at or after i, reachable from i without
            // whitespace, ?, #, "://", or the start of another quoted or bracketed item: a raw
            // quote or backtick, or the opening bracket. A stray ")" or ">" does not break it.
            var ext = Int32(-1)
            var i = n - 1
            while i >= 0 {
                let c = u[i]
                // A real closer stops when nothing is reachable from just after it.
                stop[i] = isRealCloser(u, i, closer) && ext == -1
                let schemeSep = c == colon && i + 2 < n && u[i + 1] == slash && u[i + 2] == slash
                let newItem = isQuote(closer) ? isRawCloser(u, i, closer) : c == opener
                if isPasswordStop(c) || schemeSep || newItem {
                    ext = -1
                } else if c == at && i + 1 < n && (isHostChar(u[i + 1]) || u[i + 1] == lbracket) {
                    ext = Int32(i)
                }
                i -= 1
            }
        }
        var t = Tables(stop: stop, strictNext: [Int32](repeating: -1, count: n + 1),
                       looseLast: [Int32](repeating: -1, count: n + 1))
        var i = n - 1
        while i >= 0 {
            if isPasswordStop(u[i]) || stop[i] {
                t.strictNext[i] = -1; t.looseLast[i] = -1
            } else {
                let isAt = u[i] == at
                t.strictNext[i] = isAt && hostThenEnd(u, i + 1, { _, k in stop[k] }) ? Int32(i) : t.strictNext[i + 1]
                t.looseLast[i] = t.looseLast[i + 1] != -1 ? t.looseLast[i + 1]
                    : (isAt && i + 1 < n && (isHostChar(u[i + 1]) || u[i + 1] == lbracket) ? Int32(i) : -1)
            }
            i -= 1
        }
        return t
    }

    /// Swift: the NSRanges (UTF-16) of every `user:password` span, left to right, not overlapping.
    public static func ranges(in text: String) -> [NSRange] {
        let all = Array(text.utf16)
        // Fast path: most text has no "://" at all.
        guard all.count >= 5, hasSchemeSeparator(all, 0, all.count) else { return [] }
        var out: [NSRange] = []
        var lo = 0
        while lo < all.count {
            // One whitespace-free token [lo, hi).
            while lo < all.count, isWhitespace(all[lo]) { lo += 1 }
            var hi = lo
            while hi < all.count, !isWhitespace(all[hi]) { hi += 1 }
            if hi - lo >= 5, hasSchemeSeparator(all, lo, hi) {
                for r in tokenRanges(Array(all[lo..<hi])) {
                    out.append(NSRange(location: r.location + lo, length: r.length))
                }
            }
            lo = hi
        }
        return out
    }

    /// Swift: rules 1 to 5 over one whitespace-free token. The token's end stands for the
    /// whitespace or end of text after it, which every rule treats the same way.
    private static func tokenRanges(_ u: [UInt16]) -> [NSRange] {
        let n = u.count
        var cache: [Int: Tables] = [:]
        var out: [NSRange] = []
        var lastEnd = 0
        var k = 0
        while k + 2 < n {
            if u[k] == colon && u[k + 1] == slash && u[k + 2] == slash, k + 3 >= lastEnd {
                let closer = closerFor(u, schemeSeparatorAt: k)
                let key = closer.map(Int.init) ?? -1
                if cache[key] == nil { cache[key] = tables(u, closer: closer) }
                if let end = passwordEnd(u, from: k + 3, cache[key]!) {
                    out.append(NSRange(location: k + 3, length: end - (k + 3)))
                    lastEnd = end
                    k = max(k + 1, end - 2)
                    continue
                }
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
    private static func passwordEnd(_ u: [UInt16], from start: Int, _ t: Tables) -> Int? {
        let n = u.count
        // Rule 1: username, then ":". It stops at a stopping closer.
        var k = start
        while k < n, isUserChar(u[k]), !t.stop[k] { k += 1 }
        guard k < n, u[k] == colon else { return nil }
        // Rule 2: 1 to 5 digits, then a path, query, fragment, the end or a stopping closer.
        var d = k + 1
        while d < n, d - k - 1 < 6, isDigit(u[d]) { d += 1 }
        let digits = d - k - 1
        if (1...5).contains(digits), d == n || isPortEnd(u[d]) || t.stop[d] { return nil }
        // At least one password character, then rules 4 and 5.
        let p = k + 1
        guard p + 1 < n, !isPasswordStop(u[p]), !t.stop[p] else { return nil }
        if t.strictNext[p + 1] >= 0 { return Int(t.strictNext[p + 1]) }
        if t.looseLast[p + 1] >= 0 { return Int(t.looseLast[p + 1]) }
        return nil
    }

    /// Quote-like closers (", ', backtick): the same character opens and closes, and doubling it
    /// escapes it.
    private static func isQuote(_ c: UInt16) -> Bool { c == 0x22 || c == 0x27 || c == 0x60 }

    /// Swift: rule 3, u[i] is the closer, not escaped, and for a quote not doubled.
    private static func isRawCloser(_ u: [UInt16], _ i: Int, _ closer: UInt16) -> Bool {
        guard u[i] == closer else { return false }
        if i > 0 && u[i - 1] == backslash { return false }
        if isQuote(closer) {
            if i > 0 && u[i - 1] == closer { return false }
            if i + 1 < u.count && u[i + 1] == closer { return false }
        }
        return true
    }

    /// Swift: rule 3, a raw closer followed by the end, whitespace or a delimiter.
    private static func isRealCloser(_ u: [UInt16], _ i: Int, _ closer: UInt16) -> Bool {
        guard isRawCloser(u, i, closer) else { return false }
        return i + 1 == u.count || isWhitespace(u[i + 1]) || closerFollowers.contains(u[i + 1])
    }

    private static func hasSchemeSeparator(_ u: [UInt16], _ lo: Int, _ hi: Int) -> Bool {
        var k = lo
        while k + 2 < hi {
            if u[k] == colon && u[k + 1] == slash && u[k + 2] == slash { return true }
            k += 1
        }
        return false
    }

    /// Rule 4's host: `[IPv6]` (2 to 64 of hex, ":" and ".") or 1 to 253 host characters, then
    /// a strict end: the end, whitespace, `/ ? #`, a port (":" then a digit), or a closer that
    /// `closerEnds` accepts.
    private static func hostThenEnd(_ u: [UInt16], _ h: Int,
                                    _ closerEnds: ([UInt16], Int) -> Bool) -> Bool {
        let n = u.count
        guard h < n else { return false }
        var k = h
        if u[h] == lbracket {
            k = h + 1
            while k < n, k - h - 1 <= 64, isHexColonDot(u[k]) { k += 1 }
            let count = k - h - 1
            guard (2...64).contains(count), k < n, u[k] == rbracket else { return false }
            k += 1
        } else {
            while k < n, k - h <= 253, isHostChar(u[k]) { k += 1 }
            guard (1...253).contains(k - h) else { return false }
        }
        guard k < n else { return true }
        let c = u[k]
        if c == colon { return k + 1 < n && isDigit(u[k + 1]) }
        if c == 0x2F || c == 0x3F || c == 0x23 || isWhitespace(c) { return true }   // / ? #
        return closerEnds(u, k)
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
