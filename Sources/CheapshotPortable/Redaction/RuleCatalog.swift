// Swift. The list of built-in rule names, each with a group, a plain label and a one-line
// description. It is what a person or an app switches on and off (rules file v2, NOV-156), so
// every built-in name must have exactly one entry here; RuleCatalogTests fail otherwise.
//
// The toggle unit is the rule NAME, the text inside the [NAME] placeholder. A name with several
// patterns (SECRET, STRIPE_KEY, PHONE, IPV4) switches as one.
import Foundation

public enum RuleGroup: String, CaseIterable, Sendable, Codable {
    /// Keys, tokens, passwords and anything else that lets someone act as you.
    case credentials
    /// Contact and identity details: email, phone, SSN.
    case personal
    /// Bank and card numbers.
    case financial
    /// Network addresses.
    case network

    /// What a person reads next to the group's switch.
    public var label: String {
        switch self {
        case .credentials: return "Keys, tokens and passwords"
        case .personal: return "Personal details"
        case .financial: return "Bank and card numbers"
        case .network: return "Network addresses"
        }
    }
}

public struct RuleCatalogEntry: Equatable, Sendable {
    /// The built-in rule name, as it appears inside `[NAME]`.
    public let name: String
    public let group: RuleGroup
    /// A short plain label for a switch ("AWS access key").
    public let label: String
    /// One line saying what it catches.
    public let description: String
}

/// A named set of built-in rules to switch off. `everything` switches none off.
public struct RulePreset: Equatable, Sendable {
    public let name: String
    public let label: String
    /// Built-in names this preset switches off. Never holds a custom rule name.
    public let disabled: Set<String>
}

public enum RuleCatalog {
    /// One entry per built-in name, in `Rule.builtin` order of first appearance.
    public static let entries: [RuleCatalogEntry] = [
        e("AWS_KEY", .credentials, "AWS access key", "AWS access key IDs (AKIA..., ASIA... and the other fixed prefixes)."),
        e("GITHUB_PAT", .credentials, "GitHub token", "GitHub personal access, OAuth, app and refresh tokens (ghp_, github_pat_ ...)."),
        e("GITLAB_PAT", .credentials, "GitLab token", "GitLab personal access tokens (glpat-)."),
        e("ANTHROPIC_KEY", .credentials, "Anthropic API key", "Anthropic API, admin and OAuth keys (sk-ant-)."),
        e("OPENAI_KEY", .credentials, "OpenAI API key", "OpenAI project, service-account and user keys (sk-, sk-proj- ...)."),
        e("STRIPE_KEY", .credentials, "Stripe key", "Stripe secret and restricted keys and webhook signing secrets."),
        e("SLACK_WEBHOOK", .credentials, "Slack webhook URL", "Slack incoming webhook and workflow URLs, which carry their secret in the path."),
        e("DISCORD_WEBHOOK", .credentials, "Discord webhook URL", "Discord webhook URLs, which carry their token in the path."),
        e("SLACK_TOKEN", .credentials, "Slack token", "Slack bot, user and app tokens (xoxb-, xoxp-, xapp- ...)."),
        e("NPM_TOKEN", .credentials, "npm token", "npm access tokens (npm_)."),
        e("PYPI_TOKEN", .credentials, "PyPI token", "PyPI upload tokens (pypi-)."),
        e("HF_TOKEN", .credentials, "Hugging Face token", "Hugging Face access tokens (hf_)."),
        e("TAILSCALE_KEY", .credentials, "Tailscale key", "Tailscale auth, API and OAuth keys (tskey-)."),
        e("ONEPASSWORD_TOKEN", .credentials, "1Password service token", "1Password service account tokens (ops_)."),
        e("ONEPASSWORD_SECRET_KEY", .credentials, "1Password Secret Key", "The 1Password account Secret Key from an Emergency Kit (A3-...)."),
        e("OP_REF", .credentials, "1Password reference", "op:// secret references, which name the vault and item that hold a secret."),
        e("GOOGLE_API_KEY", .credentials, "Google API key", "Google API keys (AIza...)."),
        e("GOOGLE_OAUTH_SECRET", .credentials, "Google OAuth secret", "Google OAuth client secrets (GOCSPX-)."),
        e("TWILIO_KEY", .credentials, "Twilio API key", "Twilio API key SIDs (SK followed by 32 hex digits)."),
        e("AZURE_CLIENT_SECRET", .credentials, "Azure client secret", "Microsoft Entra (Azure AD) client secrets."),
        e("VAULT_TOKEN", .credentials, "Vault token", "HashiCorp Vault service, batch and recovery tokens (hvs., hvb., hvr.)."),
        e("JWT", .credentials, "JSON Web Token", "JSON Web Tokens (three base64url parts starting eyJ)."),
        e("PRIVATE_KEY", .credentials, "Private key", "PEM and PGP private key headers."),
        e("URL_CREDS", .credentials, "Password in a URL", "The user:password part of a URL."),
        e("BEARER", .credentials, "Bearer token", "Bearer tokens after the word Bearer."),
        e("BASIC_AUTH", .credentials, "Basic auth", "HTTP Basic credentials (base64 of user:password)."),
        e("SECRET", .credentials, "Password or secret value", "Values after password, token, secret and key names; secret flags, cookies and Authorization headers."),
        e("EMAIL", .personal, "Email address", "Email addresses."),
        e("SSN", .personal, "US Social Security number", "US Social Security numbers (123-45-6789)."),
        e("PRODUCT_KEY", .credentials, "Product key", "Windows and Office product keys (five groups of five)."),
        e("IBAN", .financial, "IBAN", "International bank account numbers that pass the IBAN checksum."),
        e("ROUTING", .financial, "US routing number", "US ABA routing numbers that pass the checksum."),
        e("CARD", .financial, "Card number", "Payment card numbers that pass the Luhn check."),
        e("BANK_ACCT", .financial, "Bank account number", "Account numbers next to an account word or a routing number."),
        e("PHONE", .personal, "Phone number", "North American and international (+country) phone numbers."),
        e("TOKEN", .credentials, "Random-looking token", "Long mixed-case strings that look random, the catch-all for keys with no known prefix."),
        e("IPV4", .network, "IPv4 address", "IPv4 addresses, including ones OCR read with spaces or middle dots."),
    ]

    /// The built-in presets (Ryan, CLI Q7: "A. Two: Everything and Secrets only").
    /// `everything` is the default and today's behaviour. `secrets-only` keeps the credentials
    /// group and switches the other three groups off.
    public static let presets: [RulePreset] = [
        RulePreset(name: "everything", label: "Everything", disabled: []),
        RulePreset(name: "secrets-only", label: "Secrets only",
                   disabled: Set(entries.filter { $0.group != .credentials }.map(\.name))),
    ]

    /// The default preset's name.
    public static let defaultPreset = "everything"

    /// Every built-in name, in catalog order.
    public static var names: [String] { entries.map(\.name) }

    public static func entry(named name: String) -> RuleCatalogEntry? {
        byName[name.uppercased()]
    }

    public static func preset(named name: String) -> RulePreset? {
        presets.first { $0.name == name.lowercased() }
    }

    /// The built-in names in a group.
    public static func names(in group: RuleGroup) -> [String] {
        entries.filter { $0.group == group }.map(\.name)
    }

    /// Swift: resolves one item of a `disabled` list. A built-in name gives that name; the form
    /// `group:<group>` gives every name in the group. Nil means the item names nothing, and the
    /// caller decides whether that is an error (a named file) or a warning (the default file).
    public static func resolve(_ item: String) -> [String]? {
        let lower = item.lowercased()
        if lower.hasPrefix("group:") {
            guard let g = RuleGroup(rawValue: String(lower.dropFirst("group:".count))) else { return nil }
            return names(in: g)
        }
        return entry(named: item).map { [$0.name] }
    }

    private static let byName: [String: RuleCatalogEntry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    private static func e(_ name: String, _ group: RuleGroup, _ label: String, _ description: String) -> RuleCatalogEntry {
        RuleCatalogEntry(name: name, group: group, label: label, description: description)
    }
}
