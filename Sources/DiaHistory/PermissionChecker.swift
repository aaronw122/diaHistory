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

    /// Block until accessibility permission is granted, checking every `interval` seconds.
    /// The system dialog prompts the user to open System Settings and toggle permission on.
    static func waitForPermission(interval: TimeInterval = 5.0) {
        guard !checkAccessibility(prompt: false) else { return }

        // Trigger the system dialog — macOS will prompt the user to open
        // System Settings and grant Accessibility permission.
        _ = checkAccessibility(prompt: true)
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
