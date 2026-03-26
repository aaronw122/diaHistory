import ArgumentParser
import Foundation

@main
struct DiaHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diahistory",
        abstract: "Capture Dia browser chat conversations via the Accessibility API."
    )

    @Option(name: .long, help: "Output directory for chat files.")
    var output: String = "~/Documents/DiaChats/"

    @Flag(name: .long, help: "Run once (one-shot capture) instead of daemon mode.")
    var once: Bool = false

    @Flag(name: .long, help: "Output as JSON instead of markdown.")
    var json: Bool = false

    @Flag(name: .long, help: "Enable verbose debug logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Install as a macOS LaunchAgent (auto-start on login).")
    var install: Bool = false

    @Flag(name: .long, help: "Uninstall the macOS LaunchAgent.")
    var uninstall: Bool = false

    // MARK: - Resolved paths

    /// Expand `~` and resolve the output directory to an absolute URL.
    private var resolvedOutputDirectory: URL {
        let expanded = NSString(string: output).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: - Run

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

        let outputDir = resolvedOutputDirectory

        if once {
            try runOnce(outputDirectory: outputDir)
        } else {
            try runDaemon(outputDirectory: outputDir)
        }
    }

    // MARK: - Daemon mode

    private func runDaemon(outputDirectory: URL) throws {
        let watcher = try ChatWatcher(outputDirectory: outputDirectory)

        printBanner(mode: "daemon", outputDirectory: outputDirectory)

        if verbose {
            log("Starting ChatWatcher in daemon mode")
        }

        // Blocks indefinitely via RunLoop
        watcher.start()
    }

    // MARK: - One-shot mode

    private func runOnce(outputDirectory: URL) throws {
        printBanner(mode: "one-shot", outputDirectory: outputDirectory)

        guard let groups = AccessibilityReader.extractChatGroups() else {
            if verbose {
                log("No chat panel found in Dia")
            }
            print("No active Dia chat found.")
            throw ExitCode.failure
        }

        let messages = ChatParser.parse(groups: groups)

        if messages.isEmpty {
            print("Chat panel found but no messages detected.")
            throw ExitCode.failure
        }

        if verbose {
            log("Captured \(messages.count) message(s)")
        }

        if json {
            try outputJSON(messages: messages)
        } else {
            let writer = try MarkdownWriter(outputDirectory: outputDirectory)
            let url = try writer.write(messages: messages, date: Date())
            print("Wrote \(messages.count) message(s) to \(url.path)")
        }
    }

    // MARK: - JSON output

    private func outputJSON(messages: [ChatMessage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(messages)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ExitCode.failure
        }
        print(jsonString)
    }

    // MARK: - Helpers

    private func printBanner(mode: String, outputDirectory: URL) {
        print("diaHistory watching... (mode: \(mode), output: \(outputDirectory.path))")
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        FileHandle.standardError.write(
            Data("[\(timestamp)] \(message)\n".utf8)
        )
    }
}
