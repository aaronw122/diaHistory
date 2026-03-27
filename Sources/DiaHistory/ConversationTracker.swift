import CryptoKit
import Foundation

// MARK: - State Models

/// Persistent state tracking all known conversations.
struct ConversationState: Codable {
    var conversations: [String: ConversationRecord]  // fingerprint → record
    var activeFingerprint: String?

    static let empty = ConversationState(conversations: [:], activeFingerprint: nil)
}

/// A single conversation's metadata.
struct ConversationRecord: Codable {
    let outputFilePath: String
    let firstMessagePreview: String
    var lastMessageCount: Int
    var contentHash: String?  // Optional for backwards compat with old state files
    let createdAt: Date
}

// MARK: - Tracking Result

/// Outcome of comparing current messages against known conversations.
enum TrackingResult {
    case existingConversation(filePath: URL, newMessages: [ChatMessage])
    case newConversation(filePath: URL, allMessages: [ChatMessage])
    case noChange
}

// MARK: - ConversationTracker

/// Manages conversation identity, boundary detection, and state persistence.
///
/// Each conversation is identified by a SHA256 fingerprint of the first user message.
/// State is persisted to a JSON sidecar file so that restarts don't cause duplicate captures.
class ConversationTracker {
    let outputDirectory: URL
    private(set) var state: ConversationState

    private static let stateFilename = ".diahistory-state.json"
    private static let indexFilename = "index.md"

    // MARK: - Init

    /// Load existing state from disk, or start fresh if none exists.
    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        self.state = try Self.loadState(from: outputDirectory) ?? .empty
    }

    // MARK: - Public API

    /// Given current messages, determine if this is a new or existing conversation.
    func track(messages: [ChatMessage]) -> TrackingResult {
        guard !messages.isEmpty else { return .noChange }

        let fingerprint = Self.fingerprint(for: messages)
        let newHash = Self.contentHash(for: messages)

        // Known conversation (active or returning to) — check for changes
        if let record = state.conversations[fingerprint] {
            if fingerprint != state.activeFingerprint {
                state.activeFingerprint = fingerprint
            }

            let countChanged = messages.count != record.lastMessageCount
            let hashChanged = record.contentHash == nil || record.contentHash != newHash

            if countChanged || hashChanged {
                let filePath = outputDirectory.appendingPathComponent(record.outputFilePath)
                state.conversations[fingerprint]?.lastMessageCount = messages.count
                state.conversations[fingerprint]?.contentHash = newHash
                return .existingConversation(filePath: filePath, newMessages: messages)
            }
            return .noChange
        }

        // New conversation
        let writer = try? MarkdownWriter(outputDirectory: outputDirectory)
        let firstUserText = messages.first(where: { $0.role == .user })?.text
        let date = Date()
        let filename = writer?.filename(firstUserMessage: firstUserText, date: date)
            ?? "\(Self.dateString(from: date))/untitled.md"

        let preview = String((firstUserText ?? "untitled").prefix(80))

        let record = ConversationRecord(
            outputFilePath: filename,
            firstMessagePreview: preview,
            lastMessageCount: messages.count,
            contentHash: newHash,
            createdAt: date
        )

        state.conversations[fingerprint] = record
        state.activeFingerprint = fingerprint

        let filePath = outputDirectory.appendingPathComponent(filename)
        return .newConversation(filePath: filePath, allMessages: messages)
    }

    /// Persist state to disk atomically (write to temp, then rename).
    func save() throws {
        let stateURL = outputDirectory.appendingPathComponent(Self.stateFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            Logger.error("Failed to encode state: \(error.localizedDescription)")
            throw DiaHistoryError.stateCorrupted("Cannot encode state: \(error.localizedDescription)")
        }

        // Atomic write: temp file in same directory, then rename
        let tempURL = outputDirectory.appendingPathComponent(
            ".\(Self.stateFilename).tmp.\(UUID().uuidString)"
        )
        do {
            try data.write(to: tempURL)
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tempURL)
        } catch {
            // Clean up temp file on failure
            try? FileManager.default.removeItem(at: tempURL)
            Logger.error("Failed to save state to \(stateURL.path): \(error.localizedDescription)")
            throw DiaHistoryError.fileWriteError("Cannot save state: \(error.localizedDescription)")
        }
    }

    /// Update the index.md file listing all captured conversations.
    func updateIndex() throws {
        let indexURL = outputDirectory.appendingPathComponent(Self.indexFilename)

        // Sort conversations by creation date (newest first)
        let sorted = state.conversations.sorted { a, b in
            a.value.createdAt > b.value.createdAt
        }

        var lines: [String] = []
        lines.append("# Captured Conversations")
        lines.append("")
        lines.append("| Date | Title | Messages | File |")
        lines.append("|------|-------|----------|------|")

        for (_, record) in sorted {
            let dateStr = Self.dateString(from: record.createdAt)
            let title = record.firstMessagePreview
            let count = record.lastMessageCount
            let file = record.outputFilePath
            lines.append("| \(dateStr) | \(title) | \(count) | [\(file)](\(file)) |")
        }

        lines.append("")  // trailing newline
        let content = lines.joined(separator: "\n")

        // Atomic write
        let tempURL = outputDirectory.appendingPathComponent(
            ".\(Self.indexFilename).tmp.\(UUID().uuidString)"
        )
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.error("Failed to update index at \(indexURL.path): \(error.localizedDescription)")
            throw DiaHistoryError.fileWriteError("Cannot update index: \(error.localizedDescription)")
        }
    }

    // MARK: - Fingerprinting & Hashing

    /// Generate a SHA256 fingerprint from the first user message in the conversation.
    static func fingerprint(for messages: [ChatMessage]) -> String {
        let firstUserText = messages.first(where: { $0.role == .user })?.text ?? ""
        let data = Data(firstUserText.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hash of all message roles + texts. Detects content changes
    /// even when message count stays the same (streaming, regeneration, edits).
    static func contentHash(for messages: [ChatMessage]) -> String {
        // Use role + null separator + text per message, joined by record separator.
        // Avoids boundary ambiguity from newline-joined text.
        let canonical = messages.map { "\($0.role.rawValue)\0\($0.text)" }.joined(separator: "\u{1E}")
        let data = Data(canonical.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    /// Load persisted state from the sidecar JSON file.
    /// If the file is corrupted, logs a warning and returns empty state rather than crashing.
    private static func loadState(from directory: URL) throws -> ConversationState? {
        let stateURL = directory.appendingPathComponent(stateFilename)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            Logger.error("Failed to read state file at \(stateURL.path): \(error.localizedDescription)")
            throw DiaHistoryError.fileWriteError("Cannot read state file: \(error.localizedDescription)")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConversationState.self, from: data)
        } catch {
            // State file is corrupted — log and start fresh rather than crashing
            Logger.warn("State file corrupted, starting fresh: \(error.localizedDescription)")
            // Back up the corrupted file for debugging
            let backupURL = directory.appendingPathComponent("\(stateFilename).corrupted")
            try? FileManager.default.moveItem(at: stateURL, to: backupURL)
            return nil
        }
    }

    /// Format a date as yyyy-MM-dd.
    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
