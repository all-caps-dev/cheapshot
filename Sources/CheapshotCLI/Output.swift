import Foundation
import CheapshotCore

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
          cheapshot --ledger [--json] [--migrate]

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
          --no-ledger       do not record this run
          --version

        EXIT CODES
          0 ok   1 an input failed   2 usage error

        """
    }

    public static func json(_ object: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s + "\n"
    }
}
