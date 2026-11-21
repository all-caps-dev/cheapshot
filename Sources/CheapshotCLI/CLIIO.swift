import Foundation

/// Everything the runner touches outside its arguments, so tests can capture output and
/// redirect the home directory and the environment.
public struct CLIIO {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    public var environment: [String: String]
    public var home: String
    /// True when stdin is a terminal. `cheapshot allow` needs one (#290 item 3): an agent's shell
    /// tool runs commands with no terminal, so the model cannot approve its own raw access by
    /// running `allow`. Defaults to false so a test or embedder has to opt in on purpose.
    public var isInteractive: Bool

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                readStdin: @escaping () -> String, environment: [String: String], home: String,
                isInteractive: Bool = false) {
        self.out = out; self.err = err; self.readStdin = readStdin; self.environment = environment; self.home = home
        self.isInteractive = isInteractive
    }

    public static var standard: CLIIO {
        CLIIO(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
              err: { FileHandle.standardError.write(Data($0.utf8)) },
              readStdin: { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" },
              environment: ProcessInfo.processInfo.environment,
              home: NSHomeDirectory(),
              isInteractive: isatty(STDIN_FILENO) == 1)
    }
}
