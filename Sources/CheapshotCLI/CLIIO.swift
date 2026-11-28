import Foundation
import CheapshotCore

/// Everything the runner touches outside its arguments, so tests can capture output and
/// redirect the home directory and the environment.
public struct CLIIO {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    public var environment: [String: String]
    public var home: String
    /// True when stdin and stdout are both a terminal and this process is in that terminal's
    /// foreground process group. `cheapshot allow` needs it (#290 item 3): an agent's shell tool
    /// runs commands with no terminal, or in a background group, so `allow < /dev/tty` from the
    /// Bash tool is refused too. A speed bump, not a sandbox: anything running as the user can
    /// still fake a terminal (script(1)) or write the allow file. Defaults to false so a test or
    /// embedder has to opt in on purpose.
    public var isInteractive: Bool
    /// The clipboard `--clipboard` reads (NOV-155). nil means this platform has none the CLI can
    /// use, and the mode says so. Defaults to nil so a test or embedder never touches the real
    /// pasteboard by accident; only `standard` wires up the general pasteboard.
    public var clipboard: ClipboardSource?

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                readStdin: @escaping () -> String, environment: [String: String], home: String,
                isInteractive: Bool = false, clipboard: ClipboardSource? = nil) {
        self.out = out; self.err = err; self.readStdin = readStdin; self.environment = environment; self.home = home
        self.isInteractive = isInteractive
        self.clipboard = clipboard
    }

    public static var standard: CLIIO {
        CLIIO(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
              err: { FileHandle.standardError.write(Data($0.utf8)) },
              readStdin: { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" },
              environment: ProcessInfo.processInfo.environment,
              home: NSHomeDirectory(),
              isInteractive: foregroundTerminal(),
              clipboard: standardClipboard())
    }

    /// The general pasteboard on macOS, nil elsewhere. Building the wrapper reads nothing:
    /// the pasteboard is only touched when a `--clipboard` run asks for it.
    static func standardClipboard() -> ClipboardSource? {
        #if os(macOS)
        return PasteboardClipboard(.general)
        #else
        return nil
        #endif
    }

    /// See ``isInteractive``.
    static func foregroundTerminal() -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        let fg = tcgetpgrp(STDIN_FILENO)
        return fg != -1 && fg == getpgrp()
    }
}
