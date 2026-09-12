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
        return try entries.map { e in
            let opts: NSRegularExpression.Options = (e.caseInsensitive ?? true) ? [.caseInsensitive] : []
            do { _ = try NSRegularExpression(pattern: e.pattern, options: opts) }
            catch { throw LoadError(message: "rule \(e.name.uppercased()): invalid pattern \(e.pattern)") }
            return Rule(name: e.name.uppercased(), pattern: e.pattern, options: opts)
        }
    }
}
