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

    func run() throws {
        // Expand tilde in output path
        let expandedPath = NSString(string: output).expandingTildeInPath
        let outputURL = URL(fileURLWithPath: expandedPath)

        Logger.info("diaHistory starting...")

        // Check accessibility permission before anything else
        if !PermissionChecker.checkAccessibility(prompt: false) {
            if once {
                // One-shot mode: prompt and exit if no permission
                _ = PermissionChecker.checkAccessibility(prompt: true)
                PermissionChecker.printPermissionInstructions()
                throw DiaHistoryError.noAccessibilityPermission
            } else {
                // Daemon mode: wait for permission to be granted
                PermissionChecker.waitForPermission()
            }
        }

        Logger.info("Accessibility permission confirmed.")

        if !PermissionChecker.isCodesigned() {
            Logger.warn("Binary is not codesigned. Accessibility permission may not persist across rebuilds.")
            Logger.warn("  Run 'make build' to codesign, or use: codesign -s - .build/debug/diahistory")
        }

        // Create output directory (MarkdownWriter does this too, but fail early with a clear message)
        do {
            try FileManager.default.createDirectory(
                at: outputURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw DiaHistoryError.fileWriteError(
                "Cannot create output directory '\(outputURL.path)': \(error.localizedDescription)"
            )
        }

        if once {
            try runOnce(outputURL: outputURL)
        } else {
            try runDaemon(outputURL: outputURL)
        }
    }

    // MARK: - Modes

    private func runOnce(outputURL: URL) throws {
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

        let writer = try MarkdownWriter(outputDirectory: outputURL)
        let url = try writer.write(messages: messages, date: Date())
        Logger.info("Captured \(messages.count) messages to \(url.lastPathComponent)")
    }

    private func runDaemon(outputURL: URL) throws {
        Logger.info("Daemon mode: watching for Dia conversations...")

        let watcher = try ChatWatcher(outputDirectory: outputURL)

        // Install signal handlers for graceful shutdown
        installSignalHandlers()

        // This blocks forever (or until signal)
        watcher.start()
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
