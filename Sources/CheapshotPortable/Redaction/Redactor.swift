import Foundation

public struct RedactionReport: Equatable {
    public var counts: [String: Int] = [:]
    public var total: Int { counts.values.reduce(0, +) }
    public init(counts: [String: Int] = [:]) { self.counts = counts }
}

public struct Redactor {
    public let rules: [Rule]
    /// Rules whose pattern did not compile. They run as nothing, so a caller that built the
    /// redactor from untrusted rules must check this (or use ``init(validating:)``).
    public let compileFailures: [Rule]
    private let compiled: [Compiled]

    /// A rule with its regex built once.
    private struct Compiled {
        let rule: Rule
        let re: NSRegularExpression
        /// False for a builtin. No builtin crosses a newline (`testNewRulesStayOnOneLine`), so
        /// only the other rules get the fence-free second reading in ``redact(_:)``.
        let readsPastFences: Bool
    }

    /// Name and pattern of every builtin, to tell a builtin from a custom rule.
    private static let builtinKeys = Set(Rule.builtin.map { $0.name + "\u{0}" + $0.pattern })

    public struct CompileError: Error, Equatable, CustomStringConvertible {
        public let failures: [String]
        public var description: String {
            "rules do not compile: " + failures.joined(separator: ", ")
        }
    }

    /// A rule whose pattern will not compile is skipped and listed in ``compileFailures``.
    /// ``RuleFile`` is the validating entry point for anything a user wrote and rejects an
    /// uncompilable pattern before a `Redactor` is ever built.
    public init(rules: [Rule] = Rule.builtin) {
        self.rules = rules
        var compiled: [Compiled] = []
        var failures: [Rule] = []
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                failures.append(rule); continue
            }
            compiled.append(Compiled(rule: rule, re: re,
                                     readsPastFences: !Self.builtinKeys.contains(rule.name + "\u{0}" + rule.pattern)))
        }
        self.compiled = compiled
        self.compileFailures = failures
    }

    /// Same as ``init(rules:)`` but throws ``CompileError`` naming every rule that did not compile.
    public init(validating rules: [Rule]) throws {
        self.init(rules: rules)
        if !compileFailures.isEmpty {
            throw CompileError(failures: compileFailures.map(\.name))
        }
    }

    /// Custom rules go first so they win over the built-ins.
    public init(customRules: [Rule]) {
        self.init(rules: customRules + Rule.builtin)
    }

    public func redact(_ input: String) -> (text: String, report: RedactionReport) {
        var text = input
        var report = RedactionReport()
        // Early fence-free reading (see ``FenceTrack``): only when a custom rule could cross a
        // fence, so builtin-only redaction costs exactly what it did before.
        var track: FenceTrack? = compiled.contains(where: \.readsPastFences) && FenceFreeView.mayHaveFence(input)
            ? FenceTrack() : nil
        for (index, c) in compiled.enumerated() {
            Self.replace(hits(of: c, in: text), with: c.rule.name, in: &text, report: &report, track: &track)
            // Right after its own plain pass, a custom rule also reads the text with its fence
            // lines taken out: the same text it reads when there is no fence, before a later
            // rule (a builtin) replaces its cue (`-----BEGIN ... PRIVATE KEY-----`, an email).
            // Its hits are only recorded here and replaced at the end, so no later rule loses
            // its own cue to them (`foo\npassword` would hide `password: ...` from SECRET).
            if c.readsPastFences, track != nil, let view = FenceFreeView(text) {
                let plainNow = Set(hits(of: c, in: text))
                for r in hits(of: c, in: view.text).compactMap({ view.originalRange(of: $0, in: text) })
                where !plainNow.contains(r) {
                    let ns = NSRange(r, in: text)
                    track?.pending.append(.init(start: ns.location, end: NSMaxRange(ns), name: c.rule.name, order: index))
                }
            }
        }
        // Second reading, for rules that may span lines: the text with its code-fence lines
        // taken out. ``Layout/text(_:)`` puts a ```` ``` ```` line between a fenced line and the
        // unfenced line after it, and a document may hold fences of its own, so a custom rule
        // whose pattern spans two lines (`creds-begin\n[0-9a-f]{20}`) never matched across one
        // and its secret stayed in the text (CS-05 gap 4).
        //
        // It runs after every rule has had its plain pass, so the first loop above is exactly
        // the redaction there was before and nothing it replaces can be lost: a custom rule
        // that eats a builtin's cue (`password`) here eats it after the builtin has already
        // replaced the value. A hit the plain pass finds too is skipped (see below). A hit that
        // crosses a fence line takes that line with it, so a fenced block can be left without
        // its closing line; the secret matters more.
        // Builtins are skipped (they never cross a newline), so their output is unchanged.
        //
        // The early hits recorded in the loop above are replaced last, after this reading, so
        // everything up to here is exactly what it was without them; they only widen it.
        if compiled.contains(where: \.readsPastFences), FenceFreeView.mayHaveFence(text) {
            for c in compiled where c.readsPastFences {
                guard let view = FenceFreeView(text) else { break }
                // The same rule read plainly over the text as it is now: a view hit at one of
                // these spans is one the plain pass finds anyway (in the text a later rule
                // left), so it is not new. Every other non-empty view hit is: one that crosses a
                // fence line, and one that only sees across it (a lookbehind such as
                // `(?<=creds-begin\n)`, or `$`).
                let plainNow = Set(hits(of: c, in: text))
                let extra = hits(of: c, in: view.text).compactMap { view.originalRange(of: $0, in: text) }
                    .filter { !plainNow.contains($0) }
                Self.replace(extra, with: c.rule.name, in: &text, report: &report, track: &track)
            }
        }
        track?.apply(to: &text, report: &report)
        return (text, report)
    }

    /// Swift: the early fence-free hits of the custom rules, kept in step with the text until
    /// they are replaced at the end of ``redact(_:)``. All offsets are UTF-16 in the text as it
    /// is now; every ``replace(_:with:in:report:track:)`` moves them.
    ///
    /// Without a fence a custom rule reads the original text (custom rules go first). Across a
    /// fence it used to read the text only after the builtins, so a builtin that replaced the
    /// rule's first-line cue (PRIVATE_KEY on `-----BEGIN RSA PRIVATE KEY-----`, EMAIL on
    /// `alice@corp.com`) left the second line, the secret, in the output. Replacing an early hit
    /// right away would fix that and break the reverse: the custom rule would take away a
    /// builtin's cue (`password`) and that builtin's value would stay. Recording it and
    /// replacing it last does neither: every rule reads what it read before, and the end step
    /// only turns more of the text into a token.
    struct FenceTrack {
        /// One early hit. A replace it overlaps widens it to cover that whole new token.
        struct Pending { var start: Int; var end: Int; let name: String; let order: Int }
        var pending: [Pending] = []
        /// Every `[NAME]` token placed since the start that is still whole: sorted, never
        /// overlapping. The end step folds the tokens an early hit swallows into its own, and
        /// takes their counts back, so the report counts what is in the text (`[KEYBODY]`
        /// counts once, as it does without a fence, not as KEYBODY plus PRIVATE_KEY).
        var tokens: [(start: Int, end: Int, name: String)] = []

        /// Moves everything across one replace: each of `hits` (sorted, not overlapping, offsets
        /// in the text before it) became a token `length` units long named `name`.
        mutating func shift(_ hits: [NSRange], length: Int, name: String) {
            if hits.isEmpty { return }
            // moveBefore[k]: how far text after hits 0..<k moved (each hit's token length minus
            // its own length, added up).
            var moveBefore = [0]
            moveBefore.reserveCapacity(hits.count + 1)
            for h in hits { moveBefore.append(moveBefore[moveBefore.count - 1] + length - h.length) }
            // The first hit that ends after offset p (hits are sorted by end too). Binary search,
            // so many tokens and many hits stay n log n.
            func firstEndingAfter(_ p: Int) -> Int {
                var lo = 0, hi = hits.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if NSMaxRange(hits[mid]) <= p { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }
            // Old tokens: one a hit touches is no longer whole and drops out; the rest move.
            var old: [(start: Int, end: Int, name: String)] = []
            old.reserveCapacity(tokens.count)
            for t in tokens {
                let k = firstEndingAfter(t.start)
                if k < hits.count && hits[k].location < t.end { continue }
                old.append((t.start + moveBefore[k], t.end + moveBefore[k], t.name))
            }
            // New tokens, merged in by start (no old token overlaps a hit, so none overlap).
            var merged: [(start: Int, end: Int, name: String)] = []
            merged.reserveCapacity(old.count + hits.count)
            var oi = 0
            for (k, h) in hits.enumerated() {
                let s = h.location + moveBefore[k]
                while oi < old.count && old[oi].start < s { merged.append(old[oi]); oi += 1 }
                merged.append((s, s + length, name))
            }
            merged += old[oi...]
            tokens = merged
            // Early hits: an edge inside a hit moves out to that token's edge, so an early hit
            // never ends up covering part of a token.
            for i in pending.indices {
                let p = pending[i].start, q = pending[i].end
                let k = firstEndingAfter(p)
                pending[i].start = k < hits.count && hits[k].location < p
                    ? hits[k].location + moveBefore[k] : p + moveBefore[k]
                let j = firstEndingAfter(q)
                pending[i].end = j < hits.count && hits[j].location < q
                    ? hits[j].location + moveBefore[j] + length : q + moveBefore[j]
            }
        }

        /// Replaces the early hits. Overlapping hits become one token, named for the one that
        /// starts first (the earlier rule on a tie). Each also takes in any token it overlaps,
        /// whole, and that token's count goes back, so a hit the late reading already replaced
        /// is counted once.
        mutating func apply(to text: inout String, report: inout RedactionReport) {
            guard !pending.isEmpty else { return }
            let sorted = pending.sorted { ($0.start, $0.order) < ($1.start, $1.order) }
            // The first token that ends after offset p.
            func firstTokenEndingAfter(_ p: Int) -> Int {
                var lo = 0, hi = tokens.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if tokens[mid].end <= p { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }
            var spans: [Pending] = []
            for var s in sorted {
                var t = firstTokenEndingAfter(s.start)
                while t < tokens.count && tokens[t].start < s.end {
                    s.start = min(s.start, tokens[t].start)
                    s.end = max(s.end, tokens[t].end)
                    t += 1
                }
                if let last = spans.last, last.end > s.start {
                    spans[spans.count - 1].start = min(last.start, s.start)
                    spans[spans.count - 1].end = max(last.end, s.end)
                } else {
                    spans.append(s)
                }
            }
            // Rebuild the text on UTF-16 units. Every edge is a hit's or a token's edge, so no
            // surrogate pair is split.
            let units = Array(text.utf16)
            var out: [UInt16] = []
            out.reserveCapacity(units.count)
            var at = 0
            for s in spans {
                var t = firstTokenEndingAfter(s.start)
                while t < tokens.count && tokens[t].start < s.end {
                    let n = tokens[t].name
                    report.counts[n, default: 0] -= 1
                    if report.counts[n] == 0 { report.counts[n] = nil }
                    t += 1
                }
                report.counts[s.name, default: 0] += 1
                out += units[at..<s.start]
                out += "[\(s.name)]".utf16
                at = s.end
            }
            out += units[at...]
            text = String(decoding: out, as: UTF16.self)
            pending = []
        }
    }

    /// True when `line` is a code-fence line (``` or ~~~, as CommonMark has them), the lines the
    /// fence-free reading in ``redact(_:)`` reads past. `Masker.flag` uses it to look across an
    /// OCR'd fence line the same way.
    public static func isCodeFenceLine(_ line: String) -> Bool {
        FenceFreeView.isFence(ArraySlice(Array(line.utf16)))
    }

    /// Swift: replaces each span in `hits` (sorted, not overlapping) with `[name]` and counts it.
    /// `track`, when there is one, is moved along with the text.
    private static func replace(_ hits: [Range<String.Index>], with name: String,
                                in text: inout String, report: inout RedactionReport,
                                track: inout FenceTrack?) {
        if hits.isEmpty { return }
        if track != nil {
            // UTF-16 offsets in the text before this replace.
            track?.shift(hits.map { NSRange($0, in: text) }, length: "[\(name)]".utf16.count, name: name)
        }
        var result = ""
        var last = text.startIndex
        for r in hits {
            result += text[last..<r.lowerBound] + "[\(name)]"
            report.counts[name, default: 0] += 1
            last = r.upperBound
        }
        result += text[last...]
        text = result
    }

    /// Swift: a text with its code-fence lines removed, and the way back to the original's
    /// positions. A fence line is up to three spaces, then three or more backticks (with no
    /// other backtick after them) or three or more tildes, then anything (a language name); a
    /// trailing "\r" is allowed. Each removed line takes one adjacent newline with it, so the
    /// lines on either side become neighbours.
    struct FenceFreeView {
        /// The text without its fence lines.
        let text: String
        /// Kept stretches of the original, in order: UTF-16 start in the original and length.
        private let pieces: [(start: Int, length: Int)]
        /// Where each piece starts in ``text`` (UTF-16).
        private let viewStarts: [Int]

        /// Nil when `original` has no fence line.
        init?(_ original: String) {
            guard Self.mayHaveFence(original) else { return nil }
            let units = Array(original.utf16)
            let len = units.count
            var removed: [NSRange] = []
            var lineStart = 0
            while lineStart <= len {
                var lineEnd = lineStart
                while lineEnd < len && units[lineEnd] != 0x0A { lineEnd += 1 }
                if Self.isFence(units[lineStart..<lineEnd]) {
                    if lineEnd < len {
                        removed.append(NSRange(location: lineStart, length: lineEnd + 1 - lineStart))
                    } else if lineStart > 0 {
                        // The last line: take the newline before it instead. When that newline
                        // was already taken by a fence line just above, this one goes too.
                        let start = removed.last.map { NSMaxRange($0) == lineStart ? lineStart : lineStart - 1 } ?? lineStart - 1
                        removed.append(NSRange(location: start, length: lineEnd - start))
                    } else {
                        removed.append(NSRange(location: 0, length: len))
                    }
                }
                if lineEnd == len { break }
                lineStart = lineEnd + 1
            }
            if removed.isEmpty { return nil }
            var pieces: [(start: Int, length: Int)] = []
            var kept: [UInt16] = []
            kept.reserveCapacity(len)
            var at = 0
            for r in removed {
                if r.location > at {
                    pieces.append((at, r.location - at))
                    kept += units[at..<r.location]
                }
                at = NSMaxRange(r)
            }
            if at < len {
                pieces.append((at, len - at))
                kept += units[at..<len]
            }
            // Whole lines are removed, so no surrogate pair is split and the units decode as is.
            self.text = String(decoding: kept, as: UTF16.self)
            self.pieces = pieces
            var starts: [Int] = []
            var v = 0
            for piece in pieces { starts.append(v); v += piece.length }
            self.viewStarts = starts
        }

        /// True when `s` holds three backticks or three tildes in a row: a cheap byte scan, so a
        /// 100,000-character line with no fence costs one pass.
        static func mayHaveFence(_ s: String) -> Bool {
            var run = 0
            var last: UInt8 = 0
            for b in s.utf8 {
                if b == UInt8(ascii: "`") || b == UInt8(ascii: "~") {
                    run = b == last ? run + 1 : 1
                    if run >= 3 { return true }
                } else {
                    run = 0
                }
                last = b
            }
            return false
        }

        /// A CommonMark fence opener or closer, as described on the type, given as UTF-16 units.
        static func isFence(_ line: ArraySlice<UInt16>) -> Bool {
            let space: UInt16 = 0x20, backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E, cr: UInt16 = 0x0D
            var s = line
            if s.last == cr { s = s.dropLast() }
            let indent = s.prefix(while: { $0 == space }).count
            guard indent <= 3 else { return false }
            s = s.dropFirst(indent)
            guard let mark = s.first, mark == backtick || mark == tilde else { return false }
            let run = s.prefix(while: { $0 == mark }).count
            guard run >= 3 else { return false }
            return mark == tilde || !s.dropFirst(run).contains(backtick)
        }

        /// The original position of view offset `p`. `asEnd`: `p` is the end of a span, so a
        /// span that stops right before a removed line does not take it in. A binary search over
        /// the pieces, so a document with many fences and many hits stays linear-ish.
        private func originalOffset(_ p: Int, asEnd: Bool) -> Int? {
            guard let first = pieces.first, let lastPiece = pieces.last else { return nil }
            let total = viewStarts[viewStarts.count - 1] + lastPiece.length
            if p == 0 { return first.start }
            if p == total { return lastPiece.start + lastPiece.length }
            guard p > 0, p < total else { return nil }
            // The piece that holds view offset q: the last piece whose view start is <= q.
            let q = asEnd ? p - 1 : p
            var lo = 0, hi = viewStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if viewStarts[mid] <= q { lo = mid } else { hi = mid - 1 }
            }
            return pieces[lo].start + (q - viewStarts[lo]) + (asEnd ? 1 : 0)
        }

        /// `r`, a non-empty span in ``text``, as a span in `original`. A span that crosses a
        /// removed fence line covers that line too. Nil for an empty span.
        func originalRange(of r: Range<String.Index>, in original: String) -> Range<String.Index>? {
            let ns = NSRange(r, in: text)
            guard ns.length > 0, let lo = originalOffset(ns.location, asEnd: false),
                  let hi = originalOffset(NSMaxRange(ns), asEnd: true) else { return nil }
            return Range(NSRange(location: lo, length: hi - lo), in: original)
        }
    }

    /// Swift: the spans one rule replaces in `text`, validated, left to right, not overlapping.
    private func hits(of c: Compiled, in text: String) -> [Range<String.Index>] {
        let rule = c.rule
        if let matcher = rule.matcher {
            return matcher(text).compactMap { ns in
                guard let r = Range(ns, in: text) else { return nil }
                if let v = rule.validator, !v(String(text[r])) { return nil }
                return r
            }
        }
        if rule.rescansValues && rule.replacesCaptureGroup { return rescanningHits(c.re, rule, in: text) }
        var out: [Range<String.Index>] = []
        let ns = text as NSString
        for m in c.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // A capture-group rule replaces only the first group that took part.
            var nsRange = m.range
            if rule.replacesCaptureGroup {
                guard let g = Self.firstGroup(m) else { continue }
                nsRange = g
            }
            guard var r = Range(nsRange, in: text) else { continue }
            let hit = String(text[r])
            if let v = rule.validator, !v(hit) {
                guard rule.retryShorter, let n = Self.shorterValidPrefix(of: hit, c.re, v) else { continue }
                r = r.lowerBound..<text.index(r.lowerBound, offsetBy: n)
            }
            out.append(r)
        }
        return out
    }

    /// Swift: the scan for a rule with ``Rule/rescansValues``. Same matching as `matches(in:)`;
    /// only the resume point differs, and it is never later than the end of the match, where
    /// `matches(in:)` resumes:
    /// - an accepted value: its start, so a key inside or right after it is found;
    /// - a refused value of at most 128 characters: its start;
    /// - a longer refused value found only by reading an earlier value again (its match began
    ///   before the end of the last match the plain scan would also have found): that end, where
    ///   the plain scan resumed;
    /// - a hit that overlaps only the tail of the last span: the old end of that span.
    /// A hit wholly inside a span already redacted is dropped; one that starts inside it keeps
    /// only its tail.
    ///
    /// Linear: the resume point always moves right of the match start (a value starts after its
    /// key, and a redacted span ends after the match began). An accepted value is read again
    /// once: hits inside it are dropped and resume at their own end, and a tail is read again
    /// once from where it starts. A refused value is read again only when it is at most 128
    /// characters, or from the end of the last plain match (that end only grows, so each
    /// stretch is read again a bounded number of times). Each character is read a bounded
    /// number of times.
    private func rescanningHits(_ re: NSRegularExpression, _ rule: Rule, in text: String) -> [Range<String.Index>] {
        // One NSString for every call below, so no call bridges or copies the text again.
        let ns = NSString(string: text)
        let str = ns as String
        let len = ns.length
        // Transparent bounds: lookbehinds (the token-counter and numeric guards) see the text
        // before the search range, exactly as they do in a whole-string scan.
        let opts: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var out: [Range<String.Index>] = []
        var redactedTo = 0          // end (UTF-16) of the last redacted span
        var plainEnd = 0            // end of the last match the plain scan would also have
                                    // found (one that began at or after the previous such end)
        var pos = 0
        while pos < len,
              let m = re.firstMatch(in: str, options: opts, range: NSRange(location: pos, length: len - pos)) {
            let end = NSMaxRange(m.range)
            let began = m.range.location
            // A match that began before plainEnd was found only by reading a value again.
            let foundByRescan = began < plainEnd
            let plainResume = plainEnd
            if !foundByRescan { plainEnd = end }
            guard let cap = Self.firstGroup(m), let r = Range(cap, in: text) else { pos = end; continue }
            let capEnd = NSMaxRange(cap)
            // Already redacted as part of an earlier value.
            if capEnd <= redactedTo { pos = end; continue }
            if let v = rule.validator, !v(String(text[r])) {
                if cap.length <= 128 {
                    pos = cap.location           // short: read it again for keys inside
                } else if foundByRescan {
                    pos = plainResume            // found by reading an earlier value again: go
                                                 // back to where the plain scan resumed after it
                } else {
                    pos = end
                }
                continue
            }
            if cap.location >= redactedTo {
                out.append(r)
                pos = cap.location
            } else {
                // Overlaps the tail of the last span: redact the rest and read it again from
                // there, so a key in the tail is still found.
                if let tail = Range(NSRange(location: redactedTo, length: capEnd - redactedTo), in: text) {
                    out.append(tail)
                }
                pos = redactedTo
            }
            redactedTo = capEnd
        }
        return out
    }

    /// Swift: the range of the first capture group that took part in `m`, or nil.
    private static func firstGroup(_ m: NSTextCheckingResult) -> NSRange? {
        (1..<max(m.numberOfRanges, 1)).lazy.map { m.range(at: $0) }.first { $0.location != NSNotFound }
    }

    /// Swift: the length (in Characters) of the longest prefix of `hit` that ends just before a
    /// space, "-" or "." separator, matches the whole of `re` on its own and passes `validate`.
    /// Nil when none does. Used by rules with `retryShorter`.
    static func shorterValidPrefix(of hit: String, _ re: NSRegularExpression,
                                   _ validate: (String) -> Bool) -> Int? {
        let chars = Array(hit)
        for end in stride(from: chars.count - 1, to: 0, by: -1) where " -.".contains(chars[end]) {
            let prefix = String(chars[..<end])
            let len = (prefix as NSString).length
            guard let m = re.firstMatch(in: prefix, options: [.anchored], range: NSRange(location: 0, length: len)),
                  m.range.length == len, validate(prefix) else { continue }
            return end
        }
        return nil
    }
}
