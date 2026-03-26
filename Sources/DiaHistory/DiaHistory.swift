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

    private var resolvedOutputDirectory: URL {
        let expanded = NSString(string: output).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: - Run

    func run() throws {
        // Handle install/uninstall before anything else
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

        Logger.info("diaHistory starting...")

        // Check accessibility permission before anything else
        if !PermissionChecker.checkAccessibility(prompt: false) {
            if once {
                _ = PermissionChecker.checkAccessibility(prompt: true)
                PermissionChecker.printPermissionInstructions()
                throw DiaHistoryError.noAccessibilityPermission
            } else {
                PermissionChecker.waitForPermission()
            }
        }

        Logger.info("Accessibility permission confirmed.")

        if !PermissionChecker.isCodesigned() {
            Logger.warn("Binary is not codesigned. Accessibility permission may not persist across rebuilds.")
            Logger.warn("  Run 'make build' to codesign, or use: codesign -s - .build/debug/diahistory")
        }

        // Create output directory early to fail fast
        do {
            try FileManager.default.createDirectory(
                at: outputDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw DiaHistoryError.fileWriteError(
                "Cannot create output directory '\(outputDir.path)': \(error.localizedDescription)"
            )
        }

        if once {
            try runOnce(outputDirectory: outputDir)
        } else {
            try runDaemon(outputDirectory: outputDir)
        }
    }

    // MARK: - Daemon mode

    private func runDaemon(outputDirectory: URL) throws {
        Logger.info("Daemon mode: watching for Dia conversations... (output: \(outputDirectory.path))")

        let watcher = try ChatWatcher(outputDirectory: outputDirectory)

        installSignalHandlers()

        // Blocks indefinitely via RunLoop
        watcher.start()
    }

    // MARK: - One-shot mode

    private func runOnce(outputDirectory: URL) throws {
        Logger.info("One-shot mode: capturing current conversation...")

        guard AccessibilityReader.findDiaProcess() != nil else {
            Logger.error("Dia is not running.")
            throw DiaHistoryError.diaNotRunning
        }

        guard let groups = AccessibilityReader.extractChatGroups() else {
            Logger.error("No chat panel found in Dia.")
            throw DiaHistoryError.noChatPanel
        }

        let messages = ChatParser.parse(groups: groups)

        guard !messages.isEmpty else {
            Logger.warn("Chat panel found but no messages parsed.")
            return
        }

        if json {
            try outputJSON(messages: messages)
        } else {
            let writer = try MarkdownWriter(outputDirectory: outputDirectory)
            let url = try writer.write(messages: messages, date: Date())
            Logger.info("Captured \(messages.count) messages to \(url.lastPathComponent)")
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

    // MARK: - Signal Handling

    private func installSignalHandlers() {
        signal(SIGINT) { _ in
            Logger.info("Received SIGINT — shutting down.")
            Darwin.exit(0)
        }
        signal(SIGTERM) { _ in
            Logger.info("Received SIGTERM — shutting down.")
            Darwin.exit(0)
        }
    }
}
