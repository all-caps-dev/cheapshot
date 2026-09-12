import Foundation

extension Ledger {
    /// Where v0.4.x wrote its daily TSV files.
    public static func defaultTSVDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/cheapshot-ledger")
    }

    var migrationMarker: URL { url.deletingLastPathComponent().appendingPathComponent("migrated-tsv.json") }

    /// Imports every `*.tsv` line (ISO time, mode, inputs, image tokens, text tokens, saved,
    /// redactions) once. Leaves the TSV files in place. Returns the number of lines imported;
    /// 0 when already migrated or when the directory does not exist.
    public func migrate(fromTSVDirectory dir: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        guard !FileManager.default.fileExists(atPath: migrationMarker.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tsv") }.sorted()
        var count = 0
        for f in files {
            let body = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for line in body.split(separator: "\n") {
                let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard c.count >= 7, let inputs = Int(c[2]), let img = Int(c[3]), let txt = Int(c[4]), let red = Int(c[6]) else { continue }
                try append(LedgerEntry(ts: c[0], mode: c[1], inputs: inputs, imageTokens: img, textTokens: txt, redactions: red))
                count += 1
            }
        }
        // Only a real import gets a marker. Writing one after importing nothing locked out every
        // later `--migrate`, and the 0.4.x files may simply not be there yet the first time a
        // summary is asked for.
        if count > 0 {
            let marker: [String: Any] = ["from": dir.path, "count": count, "at": LedgerEntry.now()]
            try FileManager.default.createDirectory(at: migrationMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: migrationMarker)
        }
        return count
    }
}
