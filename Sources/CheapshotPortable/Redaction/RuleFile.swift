import Foundation

/// Reads a JSON array of {name, pattern, caseInsensitive} into rules. The CLI's --rules and
/// the app's rules editor share this format.
public enum RuleFile {
    public struct LoadError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private struct Entry: Decodable {
        var name: String
        var pattern: String
        var caseInsensitive: Bool?
    }

    public static func load(_ url: URL) throws -> [Rule] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw LoadError(message: "cannot read rules file \(url.path): \(error.localizedDescription)") }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [Rule] {
        let entries: [Entry]
        do { entries = try JSONDecoder().decode([Entry].self, from: data) }
        catch { throw LoadError(message: "rules file must be a JSON array of {name, pattern, caseInsensitive}: \(error.localizedDescription)") }
        var seen = Set<String>()
        return try entries.map { e in
            // The name is printed verbatim inside the [NAME] placeholder, so it must be a plain
            // ASCII token, and it must be unique or two rules' counts merge in the report.
            let name = e.name.uppercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw LoadError(message: "rule name \"\(e.name)\" must be letters, digits, _ or - only")
            }
            guard seen.insert(name).inserted else {
                throw LoadError(message: "duplicate rule name \(name)")
            }
            let opts: NSRegularExpression.Options = (e.caseInsensitive ?? true) ? [.caseInsensitive] : []
            do { _ = try NSRegularExpression(pattern: e.pattern, options: opts) }
            catch { throw LoadError(message: "rule \(name): invalid pattern \(e.pattern)") }
            return Rule(name: name, pattern: e.pattern, options: opts)
        }
    }
}
