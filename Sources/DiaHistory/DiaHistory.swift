import ArgumentParser
import Cocoa
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

    @Flag(name: .long, help: "Dump Dia's accessibility tree for debugging.")
    var debugTree: Bool = false

    // MARK: - Resolved paths

    private var resolvedOutputDirectory: URL {
        let expanded = NSString(string: output).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: - Run

    func run() throws {
        Logger.setVerbose(verbose)

        if uninstall {
            try LaunchAgent.uninstall()
            return
        }

        if install {
            try runInstall()
            return
        }

        // Debug tree dump — skip permission/output checks
        if debugTree {
            try dumpAccessibilityTree()
            return
        }

        let outputDir = resolvedOutputDirectory

        Logger.info("diaHistory starting...")

        try ensureAccessibilityPermission(waitForGrant: !once)
        warnIfBinaryIsNotCodesigned()
        try ensureOutputDirectoryExists(outputDir)

        if once {
            try runOnce(outputDirectory: outputDir)
        } else {
            try runDaemon(outputDirectory: outputDir)
        }
    }

    /// Stable install location — survives Homebrew upgrades and gives TCC a
    /// consistent binary identity for Accessibility permission.
    private static let stableBinDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/diahistory/bin")
    }()

    private static var stableBinaryPath: URL {
        stableBinDir.appendingPathComponent("diahistory")
    }

    private func runInstall() throws {
        let outputDir = resolvedOutputDirectory

        Logger.info("Preparing LaunchAgent installation...")

        // 1. Copy binary to stable location
        let stablePath = try installToStablePath()
        Logger.info("Binary installed to \(stablePath)")

        // 2. Request permission — the stable binary is what TCC will see
        try ensureAccessibilityPermission(waitForGrant: true)
        try ensureOutputDirectoryExists(outputDir)

        // 3. Install LaunchAgent pointing to the stable binary
        try LaunchAgent.install(binaryPath: stablePath, outputDirectory: outputDir.path)
    }

    /// Copy the current binary to a stable user-owned location.
    /// Returns the path to the stable binary.
    private func installToStablePath() throws -> String {
        let fm = FileManager.default
        let stableDir = Self.stableBinDir
        let stableBinary = Self.stableBinaryPath

        // Create directory
        try fm.createDirectory(at: stableDir, withIntermediateDirectories: true)

        // Resolve the current binary's real path (follow symlinks)
        let invocationPath = ProcessInfo.processInfo.arguments[0]
        let resolvedPath = (invocationPath as NSString).resolvingSymlinksInPath

        // Remove old binary if it exists
        if fm.fileExists(atPath: stableBinary.path) {
            try fm.removeItem(at: stableBinary)
        }

        // Copy
        try fm.copyItem(atPath: resolvedPath, toPath: stableBinary.path)

        // Codesign the stable copy
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", stableBinary.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()

        return stableBinary.path
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

        guard let capture = AccessibilityReader.getChatCapture() else {
            Logger.error("No capturable conversation found in Dia yet.")
            throw DiaHistoryError.noChatPanel
        }

        let messages = ChatParser.parse(groups: capture.groups)

        guard !messages.isEmpty else {
            Logger.warn("Conversation transcript found but no messages parsed.")
            return
        }

        if json {
            try outputJSON(messages: messages, metadata: capture.metadata)
        } else {
            let writer = try MarkdownWriter(outputDirectory: outputDirectory)
            let url = try writer.write(messages: messages, metadata: capture.metadata, date: Date())
            Logger.info("Captured \(messages.count) messages to \(url.lastPathComponent)")
        }
    }

    // MARK: - JSON output

    private func outputJSON(messages: [ChatMessage], metadata: ConversationMetadata?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ConversationExport(metadata: metadata, messages: messages))
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ExitCode.failure
        }
        print(jsonString)
    }

    // MARK: - Debug Tree Dump

    private func dumpAccessibilityTree() throws {
        guard let pid = AccessibilityReader.findDiaProcess() else {
            print("Dia process not found.")
            print("\nRunning apps with 'dia' in name/bundle:")
            for app in NSWorkspace.shared.runningApplications {
                let name = app.localizedName ?? "?"
                let bundle = app.bundleIdentifier ?? "?"
                if name.localizedCaseInsensitiveContains("dia") ||
                   bundle.localizedCaseInsensitiveContains("dia") {
                    print("  \(name) (\(bundle)) pid=\(app.processIdentifier)")
                }
            }
            return
        }

        print("Found Dia at pid \(pid)")
        let appElement = AXUIElementCreateApplication(pid)

        // Window discovery diagnostics
        let axWindows = AccessibilityReader.attribute(.windows, of: appElement) as? [AXUIElement] ?? []
        print("AXWindows: \(axWindows.count) window(s)")

        if let mainWin = AccessibilityReader.attribute(.mainWindow, of: appElement) {
            let el = mainWin as! AXUIElement
            let title = AccessibilityReader.attribute(.title, of: el) as? String ?? ""
            print("AXMainWindow: \"\(title)\"")
        } else {
            print("AXMainWindow: nil")
        }

        // Use the same discovery logic as the capture path
        let windows = AccessibilityReader.discoverWindows(appElement)
        print("Discovered \(windows.count) window(s)")

        for (i, win) in windows.enumerated() {
            let title = AccessibilityReader.attribute(.title, of: win) as? String ?? ""
            print("\n=== Window \(i): \"\(title)\" ===")
            dumpElement(win, depth: 0, maxDepth: 10)
        }
    }

    private func dumpElement(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else {
            let indent = String(repeating: "  ", count: depth)
            print("\(indent)[... max depth reached]")
            return
        }
        let indent = String(repeating: "  ", count: depth)

        let role = AccessibilityReader.attribute(.role, of: element) as? String ?? "?"
        let desc = AccessibilityReader.attribute(.description, of: element) as? String
        let value = AccessibilityReader.attribute(.value, of: element)
        let title = AccessibilityReader.attribute(.title, of: element) as? String
        let subrole = AccessibilityReader.attribute(.subrole, of: element) as? String

        var line = "\(indent)[\(role)]"
        if let subrole = subrole, !subrole.isEmpty { line += " subrole=\(subrole)" }
        if let title = title, !title.isEmpty { line += " title=\"\(title.prefix(80))\"" }
        if let desc = desc, !desc.isEmpty { line += " desc=\"\(desc.prefix(80))\"" }
        if let value = value as? String, !value.isEmpty { line += " value=\"\(value.prefix(120))\"" }
        print(line)

        // Skip menus — they're huge and not useful for chat debugging
        if role == kAXMenuBarRole as String || role == kAXMenuRole as String {
            return
        }

        guard let children = AccessibilityReader.attribute(.children, of: element) as? [AXUIElement] else {
            return
        }
        for child in children {
            dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    // MARK: - Signal Handling

    private func ensureAccessibilityPermission(waitForGrant: Bool) throws {
        guard !PermissionChecker.checkAccessibility(prompt: false) else {
            Logger.info("Accessibility permission confirmed.")
            return
        }

        if waitForGrant {
            PermissionChecker.waitForPermission()
        } else {
            _ = PermissionChecker.checkAccessibility(prompt: true)
            PermissionChecker.printPermissionInstructions()
            throw DiaHistoryError.noAccessibilityPermission
        }

        Logger.info("Accessibility permission confirmed.")
    }

    private func warnIfBinaryIsNotCodesigned() {
        if !PermissionChecker.isCodesigned() {
            Logger.warn("Binary is not codesigned. Accessibility permission may not persist across rebuilds.")
            Logger.warn("  Run 'make build' to codesign, or use: codesign -s - .build/debug/diahistory")
        }
    }

    private func ensureOutputDirectoryExists(_ outputDir: URL) throws {
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
    }

    private func installSignalHandlers() {
        signal(SIGINT) { _ in
            Logger.info("Received SIGINT — shutting down.")
            Darwin.exit(0)
        }
        signal(SIGTERM) { _ in
            Logger.info("Received SIGTERM — shutting down.")
            Darwin.exit(1)
        }
    }
}
