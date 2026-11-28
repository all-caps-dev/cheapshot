import Foundation

/// Reads a rules file. Two forms:
///
/// - Version 1, the original: a JSON array of {name, pattern, caseInsensitive}. Custom rules only.
/// - Version 2 (NOV-156), an object:
///   `{"version": 2, "preset": "secrets-only", "disabled": ["IPV4", "group:network"],
///     "presets": {"client-share": {"disabled": ["EMAIL"]}},
///     "rules": [{"name", "pattern", "caseInsensitive", "enabled"}]}`
///
/// The CLI's --rules and the app's rules editor share this format. ``parse(_:)`` and ``load(_:)``
/// read the version 1 array exactly as they always have; ``parseContents(_:strict:warn:)`` reads
/// either form. Nothing here builds a `Redactor`: ``RuleFileContents`` is plain data.
public enum RuleFile {
    public struct LoadError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The highest file version this build understands.
    public static let currentVersion = 2

    private struct Entry: Decodable {
        var name: String
        var pattern: String
        var caseInsensitive: Bool?
        /// Version 2 only. Missing means true. A version 1 array ignores it, as it always ignored
        /// unknown keys.
        var enabled: Bool?
    }

    private struct ObjectForm: Decodable {
        var version: Int?
        var preset: String?
        var disabled: [String]?
        var presets: [String: UserPreset]?
        var rules: [Entry]?
    }

    private struct UserPreset: Decodable {
        var disabled: [String]?
    }

    public static func load(_ url: URL) throws -> [Rule] {
        try parse(try read(url))
    }

    /// The version 1 array, unchanged: an object, even a valid version 2 one, is an error here.
    public static func parse(_ data: Data) throws -> [Rule] {
        let entries: [Entry]
        do { entries = try JSONDecoder().decode([Entry].self, from: data) }
        catch { throw LoadError(message: "rules file must be a JSON array of {name, pattern, caseInsensitive}: \(error.localizedDescription)") }
        return try rules(from: entries, honourEnabled: false)
    }

    /// Reads either form from disk. See ``parseContents(_:strict:warn:)``.
    public static func loadContents(_ url: URL, strict: Bool, warn: (String) -> Void) throws -> RuleFileContents {
        try parseContents(try read(url), strict: strict, warn: warn)
    }

    /// Reads either form. The failure direction is always toward more redaction (plan 4.4):
    ///
    /// | Case                         | strict (a named file) | not strict (the default file) |
    /// |------------------------------|-----------------------|-------------------------------|
    /// | not JSON, wrong shape, a bad custom rule | throws    | throws; the caller warns and runs every built-in |
    /// | `version` above 2            | throws                | throws, same                  |
    /// | unknown `preset`             | throws                | warns, preset is `everything` |
    /// | unknown name in `disabled` (or in a user preset) | throws | warns, that name is ignored |
    /// | a user preset named like a built-in one | throws     | warns, the user preset is ignored |
    /// | unknown top-level key (a misspelt `rules` would drop every custom rule) | throws | warns, the key is ignored |
    /// | an object with `version` below 2 | throws            | throws, same                  |
    ///
    /// A version 1 array gives contents with no preset and nothing disabled, so it behaves
    /// exactly as before.
    public static func parseContents(_ data: Data, strict: Bool, warn: (String) -> Void) throws -> RuleFileContents {
        // Not JSON, or not an object: the version 1 parser reports it, so the error text a
        // broken file has always produced stays the same.
        guard let top = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              top is [String: Any] || top is [Any] else {
            _ = try parse(data)
            throw LoadError(message: "rules file must be a JSON array of rules or a version 2 object")
        }

        if top is [Any] {
            return RuleFileContents(version: 1, customRules: try parse(data))
        }

        let obj: ObjectForm
        do { obj = try JSONDecoder().decode(ObjectForm.self, from: data) }
        catch { throw LoadError(message: "rules file object is malformed: \(describe(error))") }

        let version = obj.version ?? currentVersion
        // Version 1 is the plain array and nothing else, so `version` stays a reliable switch for
        // callers: an object never reads as "version 1, nothing switched off".
        guard version >= currentVersion else {
            throw LoadError(message: "rules file object version \(version) is not valid; the object form is version \(currentVersion) (version 1 is the plain array)")
        }
        guard version <= currentVersion else {
            throw LoadError(message: "rules file version \(version) is newer than this cheapshot understands (\(currentVersion)); upgrade cheapshot")
        }

        /// Reports a problem that only throws for a named file. A throw starts "rules file:", so
        /// the Read hook's broken-rules check (plugin/hooks/cheapshot-read.sh) recognises it; a
        /// warning also says what the run does instead.
        func soft(_ problem: String, instead: String) throws {
            if strict { throw LoadError(message: "rules file: \(problem)") }
            warn("\(problem); \(instead)")
        }

        /// Resolves a `disabled` list to built-in names. Unknown items throw or are dropped.
        func resolveList(_ items: [String], where context: String) throws -> Set<String> {
            var out = Set<String>()
            for item in items {
                if let names = RuleCatalog.resolve(item) {
                    out.formUnion(names)
                } else {
                    try soft("\(context): \"\(item)\" is not a built-in rule name or group", instead: "ignoring it")
                }
            }
            return out
        }

        // An unknown top-level key is never silent: custom rules live under `rules`, so a typo
        // such as "Rules" or "rule" would otherwise load a file with none of them.
        if let dict = top as? [String: Any] {
            for key in dict.keys.sorted() where !knownKeys.contains(key) {
                let hint = knownKeys.first { $0 == key.lowercased() }.map { " (did you mean \"\($0)\"?)" } ?? ""
                try soft("unknown top-level key \"\(key)\"\(hint); known keys are \(knownKeys.joined(separator: ", "))")
            }
        }

        var userPresets: [String: Set<String>] = [:]
        for (rawName, p) in (obj.presets ?? [:]).sorted(by: { $0.key < $1.key }) {
            let name = rawName.lowercased()
            if RuleCatalog.preset(named: name) != nil {
                try soft("preset \"\(rawName)\" has the name of a built-in preset", instead: "ignoring the file's version")
                continue
            }
            if userPresets[name] != nil {
                try soft("preset \"\(rawName)\" is defined twice", instead: "ignoring the second")
                continue
            }
            userPresets[name] = try resolveList(p.disabled ?? [], where: "preset \(rawName)")
        }

        var preset: String? = nil
        if let p = obj.preset {
            let lower = p.lowercased()
            if RuleCatalog.preset(named: lower) != nil || userPresets[lower] != nil {
                preset = lower
            } else {
                try soft("unknown preset \"\(p)\"", instead: "using \(RuleCatalog.defaultPreset)")
                preset = nil
            }
        }

        let disabled = try resolveList(obj.disabled ?? [], where: "disabled")
        let custom = try rules(from: obj.rules ?? [], honourEnabled: true)
        return RuleFileContents(version: version, customRules: custom, preset: preset,
                                disabled: disabled, userPresets: userPresets)
    }

    // MARK: - helpers

    /// The object form's keys, in the order the docs list them.
    static let knownKeys = ["version", "preset", "disabled", "presets", "rules"]

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }
        catch { throw LoadError(message: "cannot read rules file \(url.path): \(error.localizedDescription)") }
    }

    /// Validates custom rule entries. With `honourEnabled`, an entry with `enabled: false` is
    /// still validated (a broken pattern is an error either way) and then left out.
    private static func rules(from entries: [Entry], honourEnabled: Bool) throws -> [Rule] {
        var seen = Set<String>()
        var out: [Rule] = []
        for e in entries {
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
            if honourEnabled, e.enabled == false { continue }
            out.append(Rule(name: name, pattern: e.pattern, options: opts))
        }
        return out
    }

    /// A decoding error in one line, naming the key path when there is one.
    private static func describe(_ error: Error) -> String {
        guard let d = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? c.debugDescription : "\(p): \(c.debugDescription)"
        }
        switch d {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return path(c)
        case .keyNotFound(let k, let c): return path(c) + " (missing \(k.stringValue))"
        @unknown default: return error.localizedDescription
        }
    }
}

/// What a rules file says, validated, with no `Redactor` built yet. Turning this into the rules a
/// run uses (preset override, the all-rules switch) is a separate step.
public struct RuleFileContents {
    /// 1 for the original array, 2 for the object form.
    public let version: Int
    /// Enabled custom rules, in file order. They run before the built-ins.
    public let customRules: [Rule]
    /// The file's `preset`, lowercased, known to exist (built-in or in ``userPresets``). Nil
    /// means none set, or an unknown one was dropped with a warning; both mean `everything`.
    public let preset: String?
    /// Built-in names switched off by the file's `disabled` list, groups expanded.
    public let disabled: Set<String>
    /// The file's own presets, name (lowercased) to the built-in names each switches off.
    public let userPresets: [String: Set<String>]

    public init(version: Int, customRules: [Rule], preset: String? = nil,
                disabled: Set<String> = [], userPresets: [String: Set<String>] = [:]) {
        self.version = version; self.customRules = customRules; self.preset = preset
        self.disabled = disabled; self.userPresets = userPresets
    }
}
