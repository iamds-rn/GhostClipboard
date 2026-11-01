import Foundation
import GhostClipboardCore

@main
struct GhostClipboardCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        GhostCLIRunner.runAndExit(arguments: args)
    }

    public static func run(arguments: [String], storage: SQLiteStorageEngine? = nil) -> Int32 {
        GhostCLIRunner.run(arguments: arguments, storage: storage)
    }
}
