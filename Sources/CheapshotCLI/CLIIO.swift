import Foundation

/// Everything the runner touches outside its arguments, so tests can capture output and
/// redirect the home directory and the environment.
public struct CLIIO {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    public var environment: [String: String]
    public var home: String

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                readStdin: @escaping () -> String, environment: [String: String], home: String) {
        self.out = out; self.err = err; self.readStdin = readStdin; self.environment = environment; self.home = home
    }

    public static var standard: CLIIO {
        CLIIO(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
              err: { FileHandle.standardError.write(Data($0.utf8)) },
              readStdin: { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" },
              environment: ProcessInfo.processInfo.environment,
              home: NSHomeDirectory())
    }
}
