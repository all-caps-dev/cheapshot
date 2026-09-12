import Foundation
import CheapshotCLI

@main
struct Main {
    static func main() async {
        let code = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
