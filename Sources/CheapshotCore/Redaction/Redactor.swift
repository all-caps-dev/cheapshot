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

    /// A rule with its regexes built once.
    private struct Compiled {
        let rule: Rule
        let re: NSRegularExpression
        /// The ``Rule/NextKey`` regexes, when the rule has that step and both compile.
        let nextKey: NSRegularExpression?
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
            var nextKey: NSRegularExpression?
            if let nk = rule.nextKey {
                guard let p = try? NSRegularExpression(pattern: nk.pattern, options: rule.options) else {
                    failures.append(rule); continue
                }
                nextKey = p
            }
            compiled.append(Compiled(rule: rule, re: re, nextKey: nextKey))
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
        for c in compiled {
            let hits = self.hits(of: c, in: text)
            if hits.isEmpty { continue }
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
        if let nk = c.nextKey { return chainedHits(c.re, nk, rule, in: text) }
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

    /// Swift: the ``Rule/NextKey`` scan. Same matches as `matches(in:)`, except that after each
    /// hit the captured value is checked for being the key of the next assignment; if so, and
    /// that assignment's value passes the validator, both are redacted and the scan resumes
    /// after the value. It only ever adds hits to what `matches(in:)` finds.
    ///
    /// Linear: every step of the inner loop moves `cap` strictly right to a value that starts
    /// after the previous one ends, and each anchored try reads only a bounded key prefix (128),
    /// the key, its gap and the run of value characters after it. When that value is accepted
    /// the outer scan resumes after it; when it is refused the outer scan resumes just after
    /// `cap` and reads it once more. So each character is read a bounded number of times.
    private func chainedHits(_ re: NSRegularExpression,
                             _ nextKey: NSRegularExpression,
                             _ rule: Rule, in text: String) -> [Range<String.Index>] {
        // One NSString for every call below, so no call bridges or copies the text again.
        let ns = NSString(string: text)
        let str = ns as String
        let len = ns.length
        // Transparent bounds: lookbehinds (the token-counter and numeric guards) see the text
        // before the search range, exactly as they do in a whole-string scan.
        let opts: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var out: [Range<String.Index>] = []
        // Swift: the span of `g` in `text` when it passes the validator, else nil.
        func valid(_ g: NSRange) -> Range<String.Index>? {
            guard let r = Range(g, in: text) else { return nil }
            if let v = rule.validator, !v(String(text[r])) { return nil }
            return r
        }
        var pos = 0
        while pos < len,
              let m = re.firstMatch(in: str, options: opts, range: NSRange(location: pos, length: len - pos)) {
            var end = NSMaxRange(m.range)
            guard var cap = Self.firstGroup(m) else { pos = end; continue }
            var capSpan = valid(cap)
            while let m2 = nextKey.firstMatch(in: str, options: opts.union(.anchored),
                                                 range: NSRange(location: cap.location, length: len - cap.location)),
                  let next = Self.firstGroup(m2), next.location >= NSMaxRange(cap) {
                // `cap` is wholly the next assignment's key and separator. When that
                // assignment's value is not a secret, stop and resume the plain scan where it
                // would have resumed (just after `cap`), so nothing inside the value is skipped.
                guard let nextSpan = valid(next) else {
                    end = NSMaxRange(cap)
                    break
                }
                // Otherwise redact both. `cap` reads as a key, but a password can too
                // (`admin_pass:`), so it is never kept in the clear.
                if let s = capSpan { out.append(s) }
                cap = next
                capSpan = nextSpan
                end = NSMaxRange(m2.range)
            }
            if let s = capSpan { out.append(s) }
            pos = end
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
