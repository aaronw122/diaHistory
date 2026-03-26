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

    /// Print user-friendly instructions for granting permissions.
    static func printPermissionInstructions() {
        let message = """
        diaHistory needs Accessibility permission to read Dia's chat interface.

        To grant permission:
          1. Open System Settings → Privacy & Security → Accessibility
          2. Click the + button and add diaHistory (or toggle it on if already listed)
          3. Restart diaHistory

        If you just granted permission and it's not working, try:
          - Removing and re-adding diaHistory in the Accessibility list
          - Rebuilding with 'make build' (codesigning ensures permission persists)
        """
        print(message)
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
