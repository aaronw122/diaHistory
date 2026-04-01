import Foundation
import Testing
@testable import diahistory

struct ConversationMetadataTests {
    @Test
    func extractsDomainFromFullURL() {
        #expect(ConversationMetadata.extractDomain(from: "https://github.com/aaronw122/diaHistory") == "github.com")
    }

    @Test
    func extractsDomainFromBareHostAndPath() {
        #expect(ConversationMetadata.extractDomain(from: "docs.python.org/3/library/json.html") == "docs.python.org")
    }

    @Test
    func extractsDomainFromDiaStyleHostAndTitle() {
        #expect(ConversationMetadata.extractDomain(from: "en.wikipedia.org / Easter") == "en.wikipedia.org")
    }

    @Test
    func stripsWWWAndLowercasesHost() {
        #expect(ConversationMetadata.extractDomain(from: "WWW.Example.COM/path") == "example.com")
    }

    @Test
    func normalizesEmptyMetadata() {
        let metadata = ConversationMetadata(pageTitle: "   ", domain: "\n")
        #expect(metadata.isEmpty)
    }

    @Test
    func preservesExistingMetadataWhenNewCaptureDrifts() {
        let existing = ConversationMetadata(pageTitle: "Original Page", domain: "github.com")
        let candidate = ConversationMetadata(pageTitle: "Different Page", domain: "gitlab.com")
        let merged = ConversationMetadata.mergedPreservingExisting(existing: existing, candidate: candidate)

        #expect(merged == existing)
    }

    @Test
    func backfillsMissingFieldsWithoutReplacingExistingOnes() {
        let existing = ConversationMetadata(pageTitle: "Original Page", domain: nil)
        let candidate = ConversationMetadata(pageTitle: "Different Page", domain: "github.com")
        let merged = ConversationMetadata.mergedPreservingExisting(existing: existing, candidate: candidate)

        #expect(merged == ConversationMetadata(pageTitle: "Original Page", domain: "github.com"))
    }

    @Test
    func upgradesGenericPageTitleWhenSpecificTitleArrives() {
        let existing = ConversationMetadata(pageTitle: "Dia", domain: nil)
        let candidate = ConversationMetadata(
            pageTitle: "bootcamp-monorepo/curriculum",
            domain: "github.com"
        )
        let merged = ConversationMetadata.mergedPreservingExisting(existing: existing, candidate: candidate)

        #expect(merged == ConversationMetadata(
            pageTitle: "bootcamp-monorepo/curriculum",
            domain: "github.com"
        ))
    }

    @Test
    func preservesSpecificPageTitleOverURLLikeReplacement() {
        let existing = ConversationMetadata(
            pageTitle: "bootcamp-monorepo/curriculum",
            domain: "github.com"
        )
        let candidate = ConversationMetadata(
            pageTitle: "github.com/aaronw122/diaHistory",
            domain: "github.com"
        )
        let merged = ConversationMetadata.mergedPreservingExisting(existing: existing, candidate: candidate)

        #expect(merged == existing)
    }

    @Test
    func conversationExportEncodesMetadataEnvelope() throws {
        let export = ConversationExport(
            metadata: ConversationMetadata(pageTitle: "Original Page", domain: "github.com"),
            messages: [ChatMessage(role: .user, text: "hello")]
        )

        let data = try JSONEncoder().encode(export)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let object = try #require(rawObject as? [String: Any])
        let metadata = try #require(object["metadata"] as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])

        #expect(metadata["pageTitle"] as? String == "Original Page")
        #expect(metadata["domain"] as? String == "github.com")
        #expect(messages.count == 1)
    }

    @Test
    func conversationExportEncodesMetadataAsNullWhenUnavailable() throws {
        let export = ConversationExport(
            metadata: nil,
            messages: [ChatMessage(role: .user, text: "hello")]
        )

        let data = try JSONEncoder().encode(export)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let object = try #require(rawObject as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])

        #expect(object.keys.contains("metadata"))
        #expect(object["metadata"] is NSNull)
        #expect(messages.count == 1)
    }
}
