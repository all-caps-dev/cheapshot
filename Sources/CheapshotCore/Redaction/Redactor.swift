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

    /// Swift: the scan for a rule with ``Rule/rescansValues``. Same matches as `matches(in:)`,
    /// except where it resumes: at the start of an accepted value (so a key inside or right
    /// after it is found), and at the start of a refused value of at most 128 characters.
    /// A hit wholly inside a span already redacted is dropped; one that starts inside it keeps
    /// only its tail.
    ///
    /// Linear: the resume point always moves right (a value starts after its key). An accepted
    /// value is read again once: hits found inside it are dropped and resume after themselves,
    /// and a hit that only overlaps its tail resumes after itself too. A refused value is read
    /// again only when it is at most 128 characters. Each character is read a bounded number of
    /// times.
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
        var pos = 0
        while pos < len,
              let m = re.firstMatch(in: str, options: opts, range: NSRange(location: pos, length: len - pos)) {
            let end = NSMaxRange(m.range)
            guard let cap = Self.firstGroup(m), let r = Range(cap, in: text) else { pos = end; continue }
            let capEnd = NSMaxRange(cap)
            // Already redacted as part of an earlier value.
            if capEnd <= redactedTo { pos = end; continue }
            if let v = rule.validator, !v(String(text[r])) {
                pos = cap.length <= 128 ? cap.location : end
                continue
            }
            if cap.location >= redactedTo {
                out.append(r)
                pos = cap.location
            } else {
                // Overlaps the tail of the last span: redact the rest, and do not read it again.
                if let tail = Range(NSRange(location: redactedTo, length: capEnd - redactedTo), in: text) {
                    out.append(tail)
                }
                pos = end
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
