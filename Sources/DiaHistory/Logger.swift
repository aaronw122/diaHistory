import Foundation

/// Centralized logging to stderr so stdout stays clean for structured output.
enum Logger {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Log an informational message to stderr.
    static func info(_ message: String) {
        write("INFO", message)
    }

    /// Log a warning to stderr.
    static func warn(_ message: String) {
        write("WARN", message)
    }

    /// Log an error to stderr.
    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
