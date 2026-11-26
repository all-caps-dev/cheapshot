import Foundation

/// URL_CREDS: `user:password` inside a URL (`postgres://`, `mongodb+srv://`, `redis://:pw@host`).
/// Only the credentials go; the scheme and host stay so the line still reads.
///
/// This is a hand-written scanner, not a regex, so the password has no length cap and the run
/// time is linear. An RDS IAM auth token in a connection URL is about 700 characters; the old
/// regex capped the password at 256, because a lazy password with no cap walks to the end of
/// the line from every `://x:` (quadratic). The scanner instead precomputes, in one backward
/// pass, the next usable `@` for every position, so each `://` costs only its scheme, its
/// username and one table lookup.
///
/// Rules, in the order they are tried (``referencePattern`` is the same rules as a regex, with
/// the old caps, and the tests check that both agree on short input):
/// 1. The username is up to 128 characters of anything but whitespace, `:`, `/`, `@`, `[`, `]`,
///    and may be empty (`redis://:pw@host`, `amqps://:pw@mq`).
/// 2. A port after the colon (`localhost:3000/x@b.com`) is not a password.
/// 3. The password is one or more characters up to whitespace, `?` or `#`. When the URL opens
///    with a quote or bracket (the character before its scheme is `"`, `'`, backtick, `<` or
///    `(`), the matching closer also ends it. So two quoted URLs in one JSON line are two hits,
///    while a bare URL keeps a raw `"`, `>` or backtick inside its password, as before.
/// 4. It ends at the first `@` whose host is followed by a port (`:` and a digit), a path,
///    query or fragment, whitespace, the end, or the URL's closer. A password may hold `@`,
///    `,`, `)` or `:` (`p@ss,w0rd@host`): the `@` before them is skipped because what follows
///    it does not end like a host.
/// 5. If no `@` qualifies, the last `@` followed by a host character is used (`pg://u:p@db,
///    retry`). The password is never kept just because the host ended oddly.
/// 6. If a URL with a closer gets no hit from rules 4 and 5, they are tried again as for a bare
///    URL. So a password that holds its own closer (`"pg://u:pa\"ss1@db"` in JSON,
///    `(pg://u:Xy)9k@db)`) is still caught; it can only run past the closer, never stop short.
public enum URLCreds {
    /// The openers rule 3 knows, each with its closer.
    static let closers: [(opener: UInt16, closer: UInt16)] = [
        (0x22, 0x22), (0x27, 0x27), (0x60, 0x60), (0x3C, 0x3E), (0x28, 0x29),   // " ' ` <> ()
    ]

    /// The scanner's rules as one regex, with the old caps (username 128, password 256, host
    /// 253, scheme 32). One branch per opener, each behind a lookbehind for that opener and the
    /// scheme, plus one branch for a URL with no opener. Kept as the rule's `pattern` and as the
    /// oracle for the differential test.
    public static let referencePattern: String = {
        func esc(_ c: UInt16) -> String {
            let ch = String(UnicodeScalar(UInt8(c)))
            return ch == "`" || ch == "\"" || ch == "'" || ch == "<" || ch == ">" ? ch : "\\" + ch
        }
        // Rules 3 to 5 for one closer: the strict form, then the last-"@" fallback.
        func password(_ closer: UInt16?) -> String {
            let stop = closer.map { esc($0) } ?? ""
            let end = closer.map { "|" + esc($0) } ?? ""
            return #"[^\s?#"# + stop + #"]{1,256}?(?=@(?:\[[0-9A-Fa-f:.]{2,64}\]|[A-Za-z0-9.\-]{1,253})(?::\d|[/?#]|\s|$"# + end + "))"
                + #"|[^\s?#"# + stop + #"]{1,256}(?=@[\[A-Za-z0-9.\-])"#
        }
        // Rules 1 and 2, then the closer's forms and (rule 6) the bare-URL forms, in that order.
        func branch(_ closer: UInt16?) -> String {
            #"[^\s:/@\[\]]{0,128}:(?!\d{1,5}(?:[/?#]|\s|$))"#
                + "(?:" + password(closer) + (closer == nil ? "" : "|" + password(nil)) + ")"
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
    private static let lbracket: UInt16 = 0x5B, rbracket: UInt16 = 0x5D

    /// Rules 4 and 5 for one closer, precomputed for every position. strictNext[i] is the first
    /// index >= i holding an "@" that ends a password under rule 4, with no password stop
    /// (rule 3) between i and it; looseLast[i] is the last index >= i, before the next stop,
    /// holding an "@" followed by a host character. -1 when there is none.
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
            let c = u[i]
            if isPasswordStop(c) || c == closer {
                t.strictNext[i] = -1; t.looseLast[i] = -1
            } else {
                let isAt = c == at
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
        // Tables per closer, built the first time a URL with that opener turns up (at most six
        // passes over the text).
        var cache: [Int: Tables] = [:]
        var out: [NSRange] = []
        var lastEnd = 0
        var k = 0
        while k + 2 < n {
            if u[k] == colon && u[k + 1] == slash && u[k + 2] == slash, k + 3 >= lastEnd {
                let closer = closerFor(u, schemeSeparatorAt: k)
                // Swift: the tables for one closer (nil = a bare URL), built on first use.
                func lookup(_ c: UInt16?) -> Tables {
                    let key = c.map(Int.init) ?? -1
                    if let t = cache[key] { return t }
                    let t = tables(u, closer: c)
                    cache[key] = t
                    return t
                }
                if let end = passwordEnd(u, from: k + 3, closer, lookup) {
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
    private static func passwordEnd(_ u: [UInt16], from start: Int, _ closer: UInt16?,
                                    _ lookup: (UInt16?) -> Tables) -> Int? {
        let n = u.count
        // Rule 1: username, then ":".
        var k = start
        while k < n, k - start <= 128, isUserChar(u[k]) { k += 1 }
        guard k - start <= 128, k < n, u[k] == colon else { return nil }
        // Rule 2: 1 to 5 digits then a path, query, fragment, whitespace or the end is a port.
        var d = k + 1
        while d < n, d - k - 1 < 6, isDigit(u[d]) { d += 1 }
        let digits = d - k - 1
        if (1...5).contains(digits), d == n || isPortEnd(u[d]) { return nil }
        // Rule 3: at least one password character.
        let p = k + 1
        guard p + 1 < n, !isPasswordStop(u[p]) else { return nil }
        // Rules 4 and 5, first with the URL's closer, then (rule 6) as a bare URL.
        for c in closer == nil ? [nil] : [closer, nil] {
            if c != nil && u[p] == c { continue }
            let t = lookup(c)
            if t.strictNext[p + 1] >= 0 { return Int(t.strictNext[p + 1]) }
            if t.looseLast[p + 1] >= 0 { return Int(t.looseLast[p + 1]) }
        }
        return nil
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
        if c == closer { return true }
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
