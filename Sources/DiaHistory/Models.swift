import Foundation

struct ConversationMetadata: Codable, Equatable {
    let pageTitle: String?
    let domain: String?

    init(pageTitle: String?, domain: String?) {
        self.pageTitle = Self.normalize(pageTitle)
        self.domain = Self.normalize(domain)?.lowercased()
    }

    var isEmpty: Bool {
        pageTitle == nil && domain == nil
    }

    static func mergedPreservingExisting(
        existing: ConversationMetadata?,
        candidate: ConversationMetadata?
    ) -> ConversationMetadata? {
        switch (existing, candidate) {
        case (nil, nil):
            return nil
        case (let existing?, nil):
            return existing
        case (nil, let candidate?):
            return candidate.isEmpty ? nil : candidate
        case (let existing?, let candidate?):
            let merged = ConversationMetadata(
                pageTitle: preferredPageTitle(
                    existing: existing.pageTitle,
                    candidate: candidate.pageTitle,
                    domain: existing.domain ?? candidate.domain
                ),
                domain: existing.domain ?? candidate.domain
            )
            return merged.isEmpty ? nil : merged
        }
    }

    private static let domainRegex: NSRegularExpression? = {
        let pattern = #"(?:https?:\/\/)?(?:www\.)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?=$|[\s\/:\?#])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func extractDomain(from candidate: String?) -> String? {
        guard let candidate = normalize(candidate) else { return nil }

        let expanded = candidate.contains("://") ? candidate : "https://\(candidate)"
        if let host = URLComponents(string: expanded)?.host {
            return normalizeHost(host)
        }

        guard let regex = Self.domainRegex else { return nil }

        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, options: [], range: range),
              match.numberOfRanges > 1,
              let hostRange = Range(match.range(at: 1), in: candidate) else {
            return nil
        }

        return normalizeHost(String(candidate[hostRange]))
    }

    private static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func preferredPageTitle(
        existing: String?,
        candidate: String?,
        domain: String?
    ) -> String? {
        guard let candidate else { return existing }
        guard let existing else { return candidate }

        return titleQuality(candidate, domain: domain) > titleQuality(existing, domain: domain)
            ? candidate
            : existing
    }

    private static func titleQuality(_ title: String?, domain: String?) -> Int {
        guard let title = normalize(title) else { return 0 }

        let lowered = title.lowercased()
        let normalizedDomain = normalize(domain)?.lowercased()
        let genericTitles: Set<String> = [
            "dia",
            "new tab",
            "untitled",
            "untitled page",
            "start page",
        ]

        if genericTitles.contains(lowered) {
            return 1
        }

        if isURLLikeTitle(lowered, domain: normalizedDomain) {
            return 2
        }

        return 3
    }

    private static func isURLLikeTitle(_ loweredTitle: String, domain: String?) -> Bool {
        if loweredTitle.contains("://") || loweredTitle.hasPrefix("www.") {
            return true
        }

        if let domain, loweredTitle == domain {
            return true
        }

        if let extractedDomain = extractDomain(from: loweredTitle) {
            if let domain, extractedDomain == domain {
                return loweredTitle == domain || loweredTitle.hasPrefix("\(domain)/")
            }

            return loweredTitle == extractedDomain || loweredTitle.hasPrefix("\(extractedDomain)/")
        }

        return false
    }

    private static func normalizeHost(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("www.") {
            return String(trimmed.dropFirst(4))
        }
        return trimmed
    }
}

/// A single classified chat message from the Dia conversation.
struct ChatMessage: Codable {
    enum Role: String, Codable {
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
}

struct ConversationExport: Codable {
    let metadata: ConversationMetadata?
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case metadata
        case messages
    }

    init(metadata: ConversationMetadata?, messages: [ChatMessage]) {
        self.metadata = metadata
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(ConversationMetadata.self, forKey: .metadata)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let metadata {
            try container.encode(metadata, forKey: .metadata)
        } else {
            try container.encodeNil(forKey: .metadata)
        }
        try container.encode(messages, forKey: .messages)
    }
}
