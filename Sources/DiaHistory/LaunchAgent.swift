import Foundation

struct LaunchAgent {
    static let label = "com.diahistory.agent"
    static let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/diahistory.log").path
    static let errorLogPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/diahistory.error.log").path

    // MARK: - Public API

    static func install(binaryPath: String, outputDirectory: String) throws {
        let resolvedBinary = try resolveAndValidateBinary(binaryPath)
        let plistContent = generatePlist(binaryPath: resolvedBinary, outputDirectory: outputDirectory)

        // Ensure LaunchAgents directory exists
        let launchAgentsDir = plistPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        // Write plist
        try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
        print("Wrote plist to \(plistPath.path)")

        // Unload any existing agent first (ensures a fresh start if permission
        // was granted after a previous launch)
        try? runLaunchctl(["unload", plistPath.path])

        // Load the agent
        try runLaunchctl(["load", plistPath.path])
        print("LaunchAgent installed and loaded successfully.")
        print("  Binary: \(resolvedBinary)")
        print("  Output: \(outputDirectory)")
        print("  Logs:   \(logPath)")
        print("  Errors: \(errorLogPath)")
        print("\ndiahistory will now start automatically on login.")
    }

    static func uninstall() throws {
        guard isInstalled() else {
            print("LaunchAgent is not installed. Nothing to do.")
            return
        }

        // Unload the agent (ignore errors — it may not be loaded)
        do {
            try runLaunchctl(["unload", plistPath.path])
            print("LaunchAgent unloaded.")
        } catch {
            print("Note: could not unload agent (it may not be running). Continuing removal.")
        }

        // Remove plist file
        try FileManager.default.removeItem(at: plistPath)
        print("Removed \(plistPath.path)")
        print("LaunchAgent uninstalled successfully.")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    // MARK: - Private helpers

    private static func resolveAndValidateBinary(_ path: String) throws -> String {
        let resolved: String
        if path.hasPrefix("/") {
            resolved = path
        } else {
            resolved = FileManager.default.currentDirectoryPath + "/" + path
        }

        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw LaunchAgentError.binaryNotFound(resolved)
        }
        return resolved
    }

    private static func generatePlist(binaryPath: String, outputDirectory: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--output</string>
                <string>\(outputDirectory)</string>
            </array>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>

            <key>ThrottleInterval</key>
            <integer>30</integer>

            <key>StandardOutPath</key>
            <string>\(logPath)</string>

            <key>StandardErrorPath</key>
            <string>\(errorLogPath)</string>
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LaunchAgentError.launchctlFailed(
                arguments.joined(separator: " "),
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

enum LaunchAgentError: LocalizedError {
    case binaryNotFound(String)
    case launchctlFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "Binary not found or not executable: \(path)"
        case .launchctlFailed(let command, let output):
            return "launchctl \(command) failed: \(output)"
        }
    }
}
