import Foundation
import Testing
@testable import diahistory

struct ConversationTrackerTests {
    @Test
    func ignoresMetadataDriftAfterFirstCapture() throws {
        let outputDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let tracker = try ConversationTracker(outputDirectory: outputDirectory)
        let messages = sampleMessages()

        let initialMetadata = ConversationMetadata(pageTitle: "Original Page", domain: "github.com")
        let driftedMetadata = ConversationMetadata(pageTitle: "Different Page", domain: "gitlab.com")

        let firstResult = tracker.track(messages: messages, metadata: initialMetadata)
        guard case .newConversation = firstResult else {
            Issue.record("Expected the first capture to create a new conversation")
            return
        }

        let secondResult = tracker.track(messages: messages, metadata: driftedMetadata)
        guard case .noChange = secondResult else {
            Issue.record("Metadata drift should not trigger a rewrite once metadata is set")
            return
        }

        let stored = tracker.state.conversations.values.first?.metadata
        #expect(stored == initialMetadata)
    }

    @Test
    func backfillsMissingDomainWithoutReplacingPageTitle() throws {
        let outputDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let tracker = try ConversationTracker(outputDirectory: outputDirectory)
        let messages = sampleMessages()

        let initialMetadata = ConversationMetadata(pageTitle: "Original Page", domain: nil)
        let richerMetadata = ConversationMetadata(pageTitle: "Different Page", domain: "github.com")

        let firstResult = tracker.track(messages: messages, metadata: initialMetadata)
        guard case .newConversation = firstResult else {
            Issue.record("Expected the first capture to create a new conversation")
            return
        }

        let secondResult = tracker.track(messages: messages, metadata: richerMetadata)
        guard case .existingConversation = secondResult else {
            Issue.record("Backfilling missing metadata should trigger exactly one rewrite")
            return
        }

        let stored = tracker.state.conversations.values.first?.metadata
        #expect(stored == ConversationMetadata(pageTitle: "Original Page", domain: "github.com"))
    }

    @Test
    func upgradesGenericPageTitleOnceWhenBetterMetadataArrives() throws {
        let outputDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let tracker = try ConversationTracker(outputDirectory: outputDirectory)
        let messages = sampleMessages()

        let initialMetadata = ConversationMetadata(pageTitle: "Dia", domain: nil)
        let betterMetadata = ConversationMetadata(
            pageTitle: "bootcamp-monorepo/curriculum",
            domain: "github.com"
        )

        let firstResult = tracker.track(messages: messages, metadata: initialMetadata)
        guard case .newConversation = firstResult else {
            Issue.record("Expected the first capture to create a new conversation")
            return
        }

        let secondResult = tracker.track(messages: messages, metadata: betterMetadata)
        guard case .existingConversation = secondResult else {
            Issue.record("A better page title should trigger one corrective rewrite")
            return
        }

        let stored = tracker.state.conversations.values.first?.metadata
        #expect(stored == betterMetadata)
    }

    @Test
    func updateIndexEscapesTableCellsFromUserAndBrowserText() throws {
        let outputDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let tracker = try ConversationTracker(outputDirectory: outputDirectory)
        let messages = [
            ChatMessage(role: .user, text: "hello |\nworld"),
            ChatMessage(role: .assistant, text: "hi"),
        ]
        let metadata = ConversationMetadata(
            pageTitle: "Docs |\nReference",
            domain: "github.com"
        )

        let result = tracker.track(messages: messages, metadata: metadata)
        guard case .newConversation = result else {
            Issue.record("Expected the first capture to create a new conversation")
            return
        }

        try tracker.updateIndex()

        let indexURL = outputDirectory.appendingPathComponent("index.md")
        let index = try String(contentsOf: indexURL, encoding: .utf8)

        #expect(index.contains("| hello \\| world |"))
        #expect(index.contains("| github.com - Docs \\| Reference |"))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleMessages() -> [ChatMessage] {
        [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "hi"),
        ]
    }
}
