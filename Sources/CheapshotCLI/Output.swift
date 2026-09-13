import Foundation
import CheapshotCore

public struct OutputError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

public enum Output {
    public static func usage() -> String {
        """
        cheapshot \(cheapshotVersion) - on-device screenshot OCR for AI agents

        USAGE
          cheapshot <file.png|file.pdf> [more ...]
          cheapshot --newest [dir] [n]
          cheapshot --cleanshot [n]
          cheapshot --video <file.mp4>
          cheapshot --text <file|->        redact text instead of an image (- is stdin)
          cheapshot --ledger [--json] [--migrate] [--days <n>]
          cheapshot allow <path>           let the next Claude Code Read of <path> see the pixels (5 minutes)

        OPTIONS
          --raw             do not redact (redaction is ON by default)
          --json            emit JSON
          --stats           print token savings to stderr
          --min-conf <f>    confidence floor, default 0.3
          --rules <file>    extra redaction rules, JSON [{name, pattern, caseInsensitive}]
          --pages <N|N-M>   PDF page range, default all
          --scene <f>       video scene-change threshold, default 0.25
          --max-frames <n>  video frame cap, default 200
          --dedupe <f>      drop a screen this similar to the last, default 0.90
          --ledger          print cumulative savings across every run
          --days <n>        with --ledger: only the last n days
          --no-ledger       do not record this run
          --version

        EXIT CODES
          0 ok   1 an input failed   2 usage error

        """
    }

    /// The serializer behind `json`, swappable so a test can make it fail.
    // test seam; swapped and restored by RunnerTests
    nonisolated(unsafe) static var serialize: (Any) throws -> Data = { object in
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OutputError(message: "--json payload is not a valid JSON object")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Every caller builds the object from ints, finite doubles and strings, so a failure here is
    /// a programming error, but it is still reported as one: it used to come back as `{}` with
    /// exit 0, which a caller could take for a run with no results, and a precondition prints
    /// nothing in a release build. Callers turn the throw into a stderr line and exit 1.
    public static func json(_ object: Any) throws -> String {
        let d = try serialize(object)
        guard let s = String(data: d, encoding: .utf8) else { throw OutputError(message: "--json payload is not UTF-8") }
        return s + "\n"
    }
}
