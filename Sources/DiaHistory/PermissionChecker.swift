import ApplicationServices
import Cocoa
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

    /// The stable binary path used for TCC identity.
    static var stableBinaryPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/diahistory/bin/diahistory")
    }

    /// Open System Settings to the Accessibility pane and reveal the stable binary
    /// in Finder so the user can drag it in.
    static func openAccessibilitySettingsAndRevealBinary() {
        // Open System Settings → Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Brief delay so Settings opens first, then reveal binary in Finder.
        // Must be synchronous — this CLI has no main run loop, so
        // DispatchQueue.main.asyncAfter blocks never execute.
        Thread.sleep(forTimeInterval: 1.0)
        NSWorkspace.shared.activateFileViewerSelecting([stableBinaryPath])
    }

    /// Print user-friendly instructions for granting permissions to stderr.
    static func printPermissionInstructions() {
        let path = stableBinaryPath.path

        Logger.warn("Accessibility permission required.")
        Logger.warn("  diaHistory needs Accessibility permission to read Dia's chat interface.")
        Logger.warn("")
        Logger.warn("  System Settings and the diahistory binary have been opened for you.")
        Logger.warn("  Drag the highlighted diahistory file into the Accessibility list,")
        Logger.warn("  or click + and navigate to:")
        Logger.warn("    \(path)")
        Logger.warn("")
        Logger.warn("  Then toggle it ON. diaHistory will detect the permission automatically.")
    }

    /// Block until accessibility permission is granted, checking every `interval` seconds.
    /// Opens System Settings and reveals the binary for the user to add.
    static func waitForPermission(interval: TimeInterval = 5.0) {
        guard !checkAccessibility(prompt: false) else { return }

        // Clear stale TCC entries from previous installs so the fresh binary
        // gets a clean prompt instead of inheriting an old (wrong) entry.
        resetTCCEntry()

        // Try the system prompt first (works on some macOS versions)
        _ = checkAccessibility(prompt: true)

        // Also open Settings and reveal binary as a fallback
        openAccessibilitySettingsAndRevealBinary()
        printPermissionInstructions()
        Logger.info("Waiting for accessibility permission to be granted...")

        while !checkAccessibility(prompt: false) {
            Thread.sleep(forTimeInterval: interval)
        }

        Logger.info("Accessibility permission granted.")
    }

    // MARK: - TCC Reset

    /// Remove stale Accessibility entries for our identifier so a fresh
    /// install gets a clean TCC prompt.
    static func resetTCCEntry() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", DiaHistory.codesignIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.debug("tccutil reset failed (non-fatal): \(error)")
        }
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
