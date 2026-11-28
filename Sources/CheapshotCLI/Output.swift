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
          cheapshot [options] -- <file> ...  everything after -- is a file, even one starting with -
          cheapshot --newest [dir] [n]     a bare number is a count, not a dir (the MCP tool needs an absolute dir)
          cheapshot --cleanshot [n]
          cheapshot --video <file.mp4>
          cheapshot --text <file|->        redact text instead of an image (- is stdin)
          cheapshot --ledger [--json] [--migrate] [--days <n>] [--by-mode]
          cheapshot --list-rules [--json] [--rules <file>] [--preset <name>]
          cheapshot allow <path>           let the next Claude Code Read of <path> see the pixels (5 minutes;
                                           needs a foreground terminal; a speed bump, not a sandbox).
                                           An image is shown as a copy: pixels re-encoded as an
                                           8-bit sRGB PNG, first frame, upright, no metadata
                                           (no GPS, camera or date); a PDF as the file itself
          cheapshot mask [--out <f.png>] <image>  write a copy with every redacted or low-confidence
                                           line painted black, allow only that copy (5 minutes),
                                           print its path. The copy, default or --out, is mode 0600.
                                           Default folder: $TMPDIR/cheapshot-masked/; each run without
                                           --out deletes copies there older than 1 hour

        OPTIONS
          --raw             do not redact (redaction is ON by default)
          --json            emit JSON
          --stats           print token savings to stderr
          --min-conf <f>    confidence floor, default 0.3
          --rules <file>    rules file: a JSON array of extra rules [{name, pattern, caseInsensitive}],
                            or (0.7.0 and later) a version 2 object that can also switch built-in
                            rules off: {version, preset, disabled, presets, rules}. Without it:
                            $CHEAPSHOT_RULES, else rules.json next to the ledger if present
                            (a broken default file is skipped with a warning, all rules on)
          --preset <name>   use this preset instead of the file's: everything (default),
                            secrets-only (keys, tokens and passwords only), or one the file defines
          --all-rules       ignore every preset and switch in the rules file; all built-in rules run
          --list-rules      list the built-in rules, on or off under the current file and --preset
                            (with --json: as JSON). When any built-in rule is off, a run says so on
                            stderr, in a "rules" key in --json and as rules_off in the ledger
          --pages <N|N-M>   PDF page range, default all
          --force-ocr       OCR every PDF page, even one whose text layer checks out
          --scene <f>       video scene-change threshold, default 0.25
          --frames-at <list>  with --video: read these times instead of scene detection
                              (SS, MM:SS or HH:MM:SS, comma separated)
          --chapters <meta.json>  with --video: one frame per chapter, at its midpoint
                              (reads yt-cc's meta.json). Scene detection fires on cuts, so
                              it walks past a summary screen that is scrolled, not cut.
          --max-frames <n>  video frame cap, default 200
          --dedupe <f>      drop a screen this similar to the last, default 0.90
          --ledger          print cumulative savings across every run
          --days <n>        with --ledger: only the last n days
          --by-mode         with --ledger: split the totals by video / image / pdf, because a
                            video frame is not a screenshot you would have uploaded anyway
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
