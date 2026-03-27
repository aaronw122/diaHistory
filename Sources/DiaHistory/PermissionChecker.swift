import ApplicationServices
import Foundation

/// Checks macOS Accessibility (TCC) permission and codesigning status.
/// Call at startup before any AX operations.
struct PermissionChecker {

    // MARK: - Accessibility Permission

    /// Check if accessibility permissions are granted.
    /// If `prompt` is true, opens System Settings on first denial.
    /// Returns true if permission is granted.
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Print user-friendly instructions for granting permissions to stderr.
    static func printPermissionInstructions() {
        Logger.warn("Accessibility permission required.")
        Logger.warn("  diaHistory needs Accessibility permission to read Dia's chat interface.")
        Logger.warn("")
        Logger.warn("  To grant permission:")
        Logger.warn("    1. Open System Settings -> Privacy & Security -> Accessibility")
        Logger.warn("    2. Click the + button and add diaHistory (or toggle it on if already listed)")
        Logger.warn("    3. Restart diaHistory")
        Logger.warn("")
        Logger.warn("  If you just granted permission and it's not working, try:")
        Logger.warn("    - Removing and re-adding diaHistory in the Accessibility list")
        Logger.warn("    - Rebuilding with 'make build' (codesigning ensures permission persists)")
    }

    /// Block until accessibility permission is granted, checking every `interval` seconds.
    /// Triggers the system prompt dialog on first check, then polls silently.
    static func waitForPermission(interval: TimeInterval = 5.0) {
        guard !checkAccessibility(prompt: false) else { return }

        // Trigger the system prompt dialog
        _ = checkAccessibility(prompt: true)
        printPermissionInstructions()
        Logger.info("Waiting for accessibility permission to be granted...")

        while !checkAccessibility(prompt: false) {
            Thread.sleep(forTimeInterval: interval)
        }

        Logger.info("Accessibility permission granted.")
    }

    // MARK: - Codesigning

    /// Check if the current binary is codesigned.
    /// Uses `codesign --verify` on the running executable path.
    static func isCodesigned() -> Bool {
        let executablePath = CommandLine.arguments[0]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--quiet", executablePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
