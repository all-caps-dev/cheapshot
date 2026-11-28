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
    }

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
            compiled.append(Compiled(rule: rule, re: re))
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
        // A placeholder holds no backtick or tilde, so text with no fence run before the first
        // rule has none after any rule: check once, not once per rule.
        let mayHaveFences = FenceFreeView.mayHaveFence(input)
        // The fence-free view of `text`, built when first needed and again only after a rule
        // changes the text. The outer nil is "not built yet"; the inner nil is "no fence line".
        var view: FenceFreeView?? = nil
        for c in compiled {
            let hits: [Range<String.Index>]
            if mayHaveFences {
                if view == nil { view = .some(FenceFreeView(text)) }
                hits = self.hitsSeeingPastFences(of: c, in: text, view: view!)
            } else {
                hits = self.hits(of: c, in: text)
            }
            if hits.isEmpty { continue }
            view = nil
            var result = ""
            var last = text.startIndex
            for r in hits {
                result += text[last..<r.lowerBound] + "[\(c.rule.name)]"
                report.counts[c.rule.name, default: 0] += 1
                last = r.upperBound
            }
            result += text[last...]
            text = result
        }
        return (text, report)
    }

    /// Swift: the spans one rule replaces in `text`, plus the spans it replaces in the same text
    /// with its code-fence lines taken out, merged.
    ///
    /// Why: ``Layout/text(_:)`` puts a ```` ``` ```` line between a fenced line and the unfenced
    /// line after it, and a document may hold fences of its own. A rule whose pattern spans two
    /// lines (a custom `creds-begin\n[0-9a-f]{20}`) then no longer matched, and its secret
    /// survived in the text while the per-line redaction, which joins lines without fences,
    /// caught it. Reading the text both ways and keeping every hit from either is fail closed:
    /// nothing the plain scan replaces is dropped. A hit from the fence-free reading that spans
    /// a fence line takes that line with it.
    ///
    /// No builtin crosses a newline (see `testNewRulesStayOnOneLine`), and no builtin matches
    /// inside a fence line, so for the builtins both readings find the same spans and the
    /// output is unchanged. Text with no fence run never comes here (see `redact`).
    private func hitsSeeingPastFences(of c: Compiled, in text: String, view: FenceFreeView?) -> [Range<String.Index>] {
        let plain = hits(of: c, in: text)
        guard let view else { return plain }
        let extra = hits(of: c, in: view.text).compactMap { view.originalRange(of: $0, in: text) }
        return Self.merged(plain, extra)
    }

    /// Swift: two sorted lists of non-overlapping spans as one, with spans that overlap (or are
    /// equal) joined into a single span. Spans that only touch stay separate, as the plain scan
    /// leaves them.
    static func merged(_ a: [Range<String.Index>], _ b: [Range<String.Index>]) -> [Range<String.Index>] {
        if b.isEmpty { return a }
        let all = (a + b).sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var out: [Range<String.Index>] = []
        for r in all {
            if let last = out.last, r.lowerBound < last.upperBound || r == last {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
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

        /// `r`, a span in ``text``, as a span in `original`. A span that crosses a removed fence
        /// line covers that line too.
        func originalRange(of r: Range<String.Index>, in original: String) -> Range<String.Index>? {
            let ns = NSRange(r, in: text)
            let empty = ns.length == 0
            guard let lo = originalOffset(ns.location, asEnd: false),
                  let hi = empty ? lo : originalOffset(NSMaxRange(ns), asEnd: true) else { return nil }
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
