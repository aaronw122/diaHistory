import Foundation

/// Formats chat messages as markdown and writes them to files.
struct MarkdownWriter {
    let outputDirectory: URL

    /// Initialize with an output directory, creating it if it doesn't exist.
    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// Write a conversation to a new markdown file.
    /// Returns the URL of the created file.
    @discardableResult
    func write(messages: [ChatMessage], date: Date) throws -> URL {
        let firstUserText = messages.first(where: { $0.role == .user })?.text
        let name = filename(firstUserMessage: firstUserText, date: date)
        let fileURL = outputDirectory.appendingPathComponent(name)
        let markdown = format(messages: messages, date: date)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Generate the filename for a conversation, handling collisions.
    func filename(firstUserMessage: String?, date: Date) -> String {
        let dateString = Self.dateString(from: date)
        let slug = Self.slugify(firstUserMessage ?? "")
        let base = "\(dateString)_\(slug)"

        // Check for collisions in the output directory
        let fm = FileManager.default
        let candidate = "\(base).md"
        guard fm.fileExists(atPath: outputDirectory.appendingPathComponent(candidate).path)
        else {
            return candidate
        }

        // Append incrementing counter: -2, -3, ...
        var counter = 2
        while true {
            let numbered = "\(base)-\(counter).md"
            if !fm.fileExists(
                atPath: outputDirectory.appendingPathComponent(numbered).path)
            {
                return numbered
            }
            counter += 1
        }
    }

    /// Generate a URL-safe slug from text.
    /// - ASCII-only (transliterate unicode)
    /// - Lowercase, hyphen-joined words
    /// - Strip non-alphanumeric chars
    /// - Max length (truncate at word boundary)
    /// - Falls back to "untitled" if empty
    static func slugify(_ text: String, maxLength: Int = 40) -> String {
        // Transliterate to ASCII
        let ascii =
            text
            .applyingTransform(.toLatin, reverse: false)
            .flatMap { $0.applyingTransform(.stripDiacritics, reverse: false) }
            ?? text

        // Lowercase and keep only alphanumeric + spaces (to split on later)
        let cleaned = ascii.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(cleaned)

        // Split into words, drop empties
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "untitled" }

        // Take first 4 words
        let selected = Array(words.prefix(4))

        // Join and truncate at word boundary within maxLength
        var result = ""
        for (i, word) in selected.enumerated() {
            let candidate = i == 0 ? word : result + "-" + word
            if candidate.count > maxLength {
                break
            }
            result = candidate
        }

        return result.isEmpty ? "untitled" : result
    }

    // MARK: - Private

    /// Format messages into a markdown string.
    private func format(messages: [ChatMessage], date: Date) -> String {
        let dateString = Self.dateString(from: date)
        var lines: [String] = []
        lines.append("# Dia Chat \u{2014} \(dateString)")
        lines.append("")

        for message in messages {
            switch message.role {
            case .user:
                lines.append("**You:**")
                lines.append(message.text)
            case .assistant:
                lines.append("**Dia:**")
                lines.append(message.text)
            case .tool:
                lines.append("*\(message.text)*")
            }
            lines.append("")  // blank line between blocks
        }

        return lines.joined(separator: "\n")
    }

    /// Format a date as yyyy-MM-dd.
    private static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
