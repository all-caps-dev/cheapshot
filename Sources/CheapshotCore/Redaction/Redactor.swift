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
    private let compiled: [(Rule, NSRegularExpression)]

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
        var compiled: [(Rule, NSRegularExpression)] = []
        var failures: [Rule] = []
        for rule in rules {
            if let re = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) {
                compiled.append((rule, re))
            } else {
                failures.append(rule)
            }
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
        for (rule, re) in compiled {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var result = ""
            var last = text.startIndex
            for m in matches {
                // A capture-group rule replaces only the first group that took part.
                var nsRange = m.range
                if rule.replacesCaptureGroup {
                    guard let g = (1..<max(m.numberOfRanges, 1)).lazy.map({ m.range(at: $0) })
                        .first(where: { $0.location != NSNotFound }) else { continue }
                    nsRange = g
                }
                guard var r = Range(nsRange, in: text) else { continue }
                let hit = String(text[r])
                if let v = rule.validator, !v(hit) {
                    guard rule.retryShorter, let n = Self.shorterValidPrefix(of: hit, re, v) else { continue }
                    r = r.lowerBound..<text.index(r.lowerBound, offsetBy: n)
                }
                result += text[last..<r.lowerBound] + "[\(rule.name)]"
                report.counts[rule.name, default: 0] += 1
                last = r.upperBound
            }
            result += text[last...]
            text = result
        }
        return (text, report)
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
