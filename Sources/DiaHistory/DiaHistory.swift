import ArgumentParser
import Foundation

@main
struct DiaHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diahistory",
        abstract: "Capture Dia browser chat conversations via the Accessibility API."
    )

    @Option(name: .long, help: "Output directory for chat markdown files.")
    var output: String = "~/Documents/DiaChats/"

    @Flag(name: .long, help: "Run once (one-shot capture) instead of daemon mode.")
    var once: Bool = false

    @Flag(name: .long, help: "Install as a macOS LaunchAgent (auto-start on login).")
    var install: Bool = false

    @Flag(name: .long, help: "Uninstall the macOS LaunchAgent.")
    var uninstall: Bool = false

    func run() throws {
        if install {
            let binaryPath = ProcessInfo.processInfo.arguments[0]
            let resolvedOutput = NSString(string: output).expandingTildeInPath
            try LaunchAgent.install(binaryPath: binaryPath, outputDirectory: resolvedOutput)
            return
        }

        if uninstall {
            try LaunchAgent.uninstall()
            return
        }

        print("diahistory starting...")
    }
}
