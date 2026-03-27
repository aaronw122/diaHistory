import Foundation

/// Domain errors for diaHistory.
enum DiaHistoryError: Error, LocalizedError {
    case noAccessibilityPermission
    case diaNotRunning
    case noChatPanel
    case fileWriteError(String)
    case stateCorrupted(String)

    var errorDescription: String? {
        switch self {
        case .noAccessibilityPermission:
            return "Accessibility permission not granted"
        case .diaNotRunning:
            return "Dia browser is not running"
        case .noChatPanel:
            return "No capturable conversation found in Dia yet"
        case .fileWriteError(let detail):
            return "File write failed: \(detail)"
        case .stateCorrupted(let detail):
            return "State file corrupted: \(detail)"
        }
    }
}
