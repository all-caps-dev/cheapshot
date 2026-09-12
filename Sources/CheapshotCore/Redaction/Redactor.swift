import Foundation

public struct RedactionReport: Equatable {
    public var counts: [String: Int] = [:]
    public var total: Int { counts.values.reduce(0, +) }
    public init(counts: [String: Int] = [:]) { self.counts = counts }
}

public struct Redactor {
    public let rules: [Rule]
    private let compiled: [(Rule, NSRegularExpression)]

    public init(rules: [Rule] = Rule.builtin) {
        self.rules = rules
        self.compiled = rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: rule.options)).map { (rule, $0) }
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
                guard let r = Range(m.range, in: text) else { continue }
                let hit = String(text[r])
                if let v = rule.validator, !v(hit) { continue }
                result += text[last..<r.lowerBound] + "[\(rule.name)]"
                report.counts[rule.name, default: 0] += 1
                last = r.upperBound
            }
            result += text[last...]
            text = result
        }
        return (text, report)
    }
}
