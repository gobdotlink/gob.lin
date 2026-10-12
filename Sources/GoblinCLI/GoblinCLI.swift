import Foundation
import GoblinCore
import GoblinEngines

@main
struct GoblinCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments {
        case ["--version"]:
            print("\(GoblinMetadata.name) \(GoblinMetadata.version)")
        case ["--self-check"]:
            let request = TranscriptionRequest(audioFileURL: URL(fileURLWithPath: "/tmp/goblin-smoke.wav"))
            precondition(request.audioFileURL.isFileURL)
            precondition(!GoblinMetadata.bundleIdentifier.isEmpty)
            print("GoblinCore and GoblinEngines loaded successfully.")
        case [], ["--help"], ["-h"]:
            print("""
            goblin — the gob.lin command-line companion

            Usage: goblin --version | --self-check | --help

            Speech recognition is added after the engine benchmark.
            """)
        default:
            FileHandle.standardError.write(Data("Unknown arguments. Run goblin --help.\n".utf8))
            exit(2)
        }
    }
}
