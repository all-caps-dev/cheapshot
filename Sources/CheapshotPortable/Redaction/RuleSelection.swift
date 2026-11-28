// Swift. Turns what a rules file says (RuleFileContents), a --preset override and the caller's
// toggle policy into the rules one run uses (NOV-156). The Redactor never sees a file or a
// preset name: it gets the resulting rule list from ``Redactor/init(selection:)``.
import Foundation

/// Whether a caller lets a rules file switch built-in rules off.
///
/// This is the switch for Ryan's open question Q5 ("May rules.json switch off built-in rules for
/// agent reads?"). Each answer is one value here, picked by the caller:
/// - A: agent reads (the hook, the MCP server) pass `--all-rules`, which is ``allRules``;
///   everything else uses ``honour``.
/// - B: every caller uses ``honour``.
/// - C: every caller uses `locked([.credentials])`.
public enum RuleTogglePolicy: Equatable, Sendable {
    /// Apply the file's preset and `disabled` list.
    case honour
    /// Ignore every toggle and preset: all built-in rules run. Custom rules still apply.
    case allRules
    /// Apply toggles, except that no built-in in these groups can be switched off.
    case locked(Set<RuleGroup>)
}

public struct RuleSelection {
    /// Enabled custom rules from the file, in file order. They run first, so they win.
    public let customRules: [Rule]
    /// The preset in force: the --preset override, else the file's, else `everything`.
    public let preset: String
    /// Built-in names switched off for this run, in catalog order. Empty on a default run.
    public let disabled: [String]

    /// True when any built-in rule is off. A weakened run must say so (stderr, JSON, ledger).
    public var isWeakened: Bool { !disabled.isEmpty }

    /// Built-in rules that are on but catch less because a rule they lean on is off, with the
    /// reason, in catalog order (``RuleCatalog/dependencies``). Empty when nothing is off.
    public var partial: [(name: String, lost: String)] {
        let off = Set(disabled)
        return RuleCatalog.dependencies
            .filter { off.contains($0.needs) && !off.contains($0.rule) }
            .map { (name: $0.rule, lost: $0.lost) }
    }

    /// The rules to run: custom rules first, then the built-ins that are on, in their order.
    public var rules: [Rule] {
        let off = Set(disabled)
        return customRules + Rule.builtin.filter { !off.contains($0.name) }
    }

    /// No file, no preset: every built-in rule. Today's default.
    public static let everything = RuleSelection(customRules: [], preset: RuleCatalog.defaultPreset, disabled: [])

    public struct PresetError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Resolves a selection.
    ///
    /// - `contents`: the parsed rules file, or nil when there is none (or the default file was
    ///   dropped with a warning).
    /// - `presetOverride`: `--preset`. It replaces the file's `preset`; the file's `disabled`
    ///   list still applies. A name that is neither built-in nor one of the file's presets
    ///   throws, for a named file and the default file alike (plan 4.4, last row).
    /// - `policy`: see ``RuleTogglePolicy``. ``RuleTogglePolicy/allRules`` wins over every toggle
    ///   and preset. It does not hide a typo: an unknown `--preset` still throws under it, on
    ///   purpose, and the hook and MCP server never pass `--preset`.
    public static func resolve(_ contents: RuleFileContents?, presetOverride: String? = nil,
                               policy: RuleTogglePolicy = .honour) throws -> RuleSelection {
        let custom = contents?.customRules ?? []
        let userPresets = contents?.userPresets ?? [:]

        var presetName = contents?.preset ?? RuleCatalog.defaultPreset
        if let o = presetOverride {
            let lower = o.lowercased()
            guard RuleCatalog.preset(named: lower) != nil || userPresets[lower] != nil else {
                let known = RuleCatalog.presets.map(\.name) + userPresets.keys.sorted()
                throw PresetError(message: "--preset: unknown preset \"\(o)\" (known: \(known.joined(separator: ", ")))")
            }
            presetName = lower
        }

        if policy == .allRules {
            return RuleSelection(customRules: custom, preset: RuleCatalog.defaultPreset, disabled: [])
        }

        // A built-in preset name always means the built-in preset: the parser refuses a user
        // preset that shadows one, and this lookup order makes sure of it.
        var off = RuleCatalog.preset(named: presetName)?.disabled ?? userPresets[presetName] ?? []
        off.formUnion(contents?.disabled ?? [])
        if case .locked(let groups) = policy {
            off.subtract(groups.flatMap { RuleCatalog.names(in: $0) })
        }
        // Only real built-in names, in catalog order, so output is stable.
        let disabled = RuleCatalog.names.filter { off.contains($0) }
        return RuleSelection(customRules: custom, preset: presetName, disabled: disabled)
    }

    public init(customRules: [Rule], preset: String, disabled: [String]) {
        self.customRules = customRules; self.preset = preset; self.disabled = disabled
    }
}

extension Redactor {
    /// The redactor for a resolved selection: custom rules first, then the built-ins left on.
    public init(selection: RuleSelection) {
        self.init(rules: selection.rules)
    }
}
