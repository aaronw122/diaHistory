import CryptoKit
import Foundation

// MARK: - State Models

/// Persistent state tracking all known conversations.
struct ConversationState: Codable {
    var conversations: [String: ConversationRecord]  // fingerprint → record
    // Multiple panels can be active simultaneously across Dia windows.
    // All active fingerprints are exempt from pruning.
    var activeFingerprints: Set<String>

    // Backwards-compatible decoding: old state files have `activeFingerprint: String?`
    enum CodingKeys: String, CodingKey {
        case conversations
        case activeFingerprints
        case activeFingerprint  // legacy
    }

    init(conversations: [String: ConversationRecord] = [:], activeFingerprints: Set<String> = []) {
        self.conversations = conversations
        self.activeFingerprints = activeFingerprints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decode([String: ConversationRecord].self, forKey: .conversations)
        if let set = try container.decodeIfPresent(Set<String>.self, forKey: .activeFingerprints) {
            activeFingerprints = set
        } else if let single = try container.decodeIfPresent(String.self, forKey: .activeFingerprint) {
            activeFingerprints = [single]
        } else {
            activeFingerprints = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversations, forKey: .conversations)
        try container.encode(activeFingerprints, forKey: .activeFingerprints)
    }

    static let empty = ConversationState()
}

/// A single conversation's metadata.
struct ConversationRecord: Codable {
    let outputFilePath: String
    let firstMessagePreview: String
    var lastMessageCount: Int
    var contentHash: String?  // Optional for backwards compat with old state files
    var metadata: ConversationMetadata?
    let createdAt: Date
    var lastUpdatedAt: Date?  // nil for records from older state files
    var messageFingerprint: String?  // Domain-free fingerprint for cross-domain fallback lookup
}

// MARK: - Tracking Result

/// Outcome of comparing current messages against known conversations.
enum TrackingResult {
    case existingConversation(filePath: URL, createdAt: Date, metadata: ConversationMetadata?)
    case newConversation(filePath: URL, createdAt: Date, metadata: ConversationMetadata?)
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

    /// Update the set of currently active fingerprints (for prune exemption).
    func setActiveFingerprints(_ fingerprints: Set<String>) {
        state.activeFingerprints = fingerprints
    }

    /// Given current messages, determine if this is a new or existing conversation.
    func track(messages: [ChatMessage], metadata: ConversationMetadata?) -> TrackingResult {
        guard !messages.isEmpty else { return .noChange }

        let fingerprint = Self.fingerprint(for: messages, domain: metadata?.domain)
        let newHash = Self.contentHash(for: messages)

        // If domain changed or arrived late, the fingerprint won't match.
        // Fall back to message-only fingerprint to find the existing conversation,
        // then migrate it to the new key. Also provides backward compat with
        // pre-domain state files.
        if state.conversations[fingerprint] == nil {
            let msgFP = Self.fingerprint(for: messages)
            // Try legacy key (pre-domain state files stored under message-only fingerprint)
            let legacyKey = state.conversations[msgFP] != nil ? msgFP : nil
            // Try matching by stored messageFingerprint (domain drift)
            let driftKey = state.conversations.first(where: { $0.value.messageFingerprint == msgFP })?.key
            if let oldKey = legacyKey ?? driftKey, oldKey != fingerprint {
                state.conversations[fingerprint] = state.conversations[oldKey]
                state.conversations.removeValue(forKey: oldKey)
                state.activeFingerprints.remove(oldKey)
            }
        }

        // Known conversation (active or returning to) — check for changes
        if let record = state.conversations[fingerprint] {
            state.activeFingerprints.insert(fingerprint)

            let countChanged = messages.count != record.lastMessageCount
            let hashChanged = record.contentHash == nil || record.contentHash != newHash
            let mergedMetadata = ConversationMetadata.mergedPreservingExisting(
                existing: record.metadata,
                candidate: metadata
            )
            let metadataBackfilled = record.metadata != mergedMetadata

            if countChanged || hashChanged || metadataBackfilled {
                let filePath = outputDirectory.appendingPathComponent(record.outputFilePath)
                state.conversations[fingerprint]?.lastMessageCount = messages.count
                state.conversations[fingerprint]?.contentHash = newHash
                state.conversations[fingerprint]?.metadata = mergedMetadata
                state.conversations[fingerprint]?.lastUpdatedAt = Date()
                return .existingConversation(
                    filePath: filePath,
                    createdAt: record.createdAt,
                    metadata: mergedMetadata
                )
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
            metadata: ConversationMetadata.mergedPreservingExisting(existing: nil, candidate: metadata),
            createdAt: date,
            messageFingerprint: Self.fingerprint(for: messages)
        )

        state.conversations[fingerprint] = record
        state.activeFingerprints.insert(fingerprint)
        state.conversations[fingerprint]?.lastUpdatedAt = date

        let filePath = outputDirectory.appendingPathComponent(filename)
        return .newConversation(
            filePath: filePath,
            createdAt: date,
            metadata: record.metadata
        )
    }

    /// Remove conversations inactive for more than 1 day.
    /// The markdown files on disk are the source of truth — pruning here
    /// only affects the in-memory tracking dict and its serialized form.
    func pruneStaleConversations() {
        let cutoff = Date().addingTimeInterval(-86400)  // 24 hours
        let before = state.conversations.count
        state.conversations = state.conversations.filter { key, record in
            if state.activeFingerprints.contains(key) { return true }
            let lastActive = record.lastUpdatedAt ?? record.createdAt
            return lastActive > cutoff
        }
        let pruned = before - state.conversations.count
        if pruned > 0 {
            Logger.info("Pruned \(pruned) stale conversation(s) from state")
        }
    }

    /// Persist state to disk atomically (write to temp, then rename).
    func save() throws {
        pruneStaleConversations()
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
        lines.append("| Date | Title | Context | Messages | File |")
        lines.append("|------|-------|---------|----------|------|")

        for (_, record) in sorted {
            let dateStr = Self.dateString(from: record.createdAt)
            let title = Self.sanitizedIndexTableCell(record.firstMessagePreview)
            let context = Self.sanitizedIndexTableCell(Self.indexContext(for: record.metadata))
            let count = record.lastMessageCount
            let file = record.outputFilePath
            lines.append("| \(dateStr) | \(title) | \(context) | \(count) | [\(file)](\(file)) |")
        }

        lines.append("")  // trailing newline
        let content = lines.joined(separator: "\n")

        // Atomic write
        let tempURL = outputDirectory.appendingPathComponent(
            ".\(Self.indexFilename).tmp.\(UUID().uuidString)"
        )
        do {
            try content.write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.error("Failed to update index at \(indexURL.path): \(error.localizedDescription)")
            throw DiaHistoryError.fileWriteError("Cannot update index: \(error.localizedDescription)")
        }
    }

    // MARK: - Fingerprinting & Hashing

    /// Generate a SHA256 fingerprint from the domain (if available) and the first
    /// user message. Including the domain prevents collisions when the same first
    /// message is sent on different sites (e.g. "hello" on claude.ai vs chatgpt.com).
    static func fingerprint(for messages: [ChatMessage], domain: String? = nil) -> String {
        let firstUserText = messages.first(where: { $0.role == .user })?.text ?? ""
        let input = (domain ?? "") + "\0" + firstUserText
        let data = Data(input.utf8)
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

    private static func indexContext(for metadata: ConversationMetadata?) -> String {
        guard let metadata else { return "" }

        if let pageTitle = metadata.pageTitle, let domain = metadata.domain {
            return "\(domain) - \(pageTitle)"
        }

        return metadata.pageTitle ?? metadata.domain ?? ""
    }

    static func sanitizedIndexTableCell(_ value: String) -> String {
        let normalizedWhitespace = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedWhitespace.replacingOccurrences(of: "|", with: #"\|"#)
    }
}
