import ApplicationServices
import Foundation

/// A single classified chat message from the Dia conversation.
struct ChatMessage {
    enum Role: String {
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
}

/// Classifies AXGroup elements into structured chat messages.
struct ChatParser {

    /// Parse AXGroup elements into structured chat messages.
    /// Groups that don't match known patterns (buttons, spacers) are skipped.
    static func parse(groups: [AXUIElement]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for group in groups {
            if let message = classify(group: group) {
                messages.append(message)
            }
        }
        return messages
    }

    // MARK: - Private

    /// Attempt to classify a single AXGroup into a ChatMessage.
    /// Returns nil for groups that should be skipped (buttons-only, empty, etc.).
    private static func classify(group: AXUIElement) -> ChatMessage? {
        guard let children = axChildren(of: group), !children.isEmpty else {
            // Empty children → spacer/UI chrome → skip
            return nil
        }

        let roles = children.compactMap { axRole(of: $0) }

        // Buttons only → action row → skip
        if roles.allSatisfy({ $0 == kAXButtonRole as String }) {
            return nil
        }

        let hasImage = roles.contains(kAXImageRole as String)
        let hasTextArea = roles.contains(kAXTextAreaRole as String)
        let hasStaticText = roles.contains(kAXStaticTextRole as String)

        // AXImage + AXTextArea → user message
        if hasImage && hasTextArea {
            let text = firstTextAreaValue(in: children)
            return text.map { ChatMessage(role: .user, text: $0) }
        }

        // AXTextArea only (no AXImage) → assistant response
        if hasTextArea && !hasImage {
            let text = firstTextAreaValue(in: children)
            return text.map { ChatMessage(role: .assistant, text: $0) }
        }

        // AXStaticText elements → tool use, concatenate values
        if hasStaticText {
            let texts = children.compactMap { child -> String? in
                guard axRole(of: child) == kAXStaticTextRole as String else { return nil }
                return axValue(of: child)
            }
            guard !texts.isEmpty else { return nil }
            return ChatMessage(role: .tool, text: texts.joined(separator: " "))
        }

        // Unknown pattern → skip
        return nil
    }

    /// Extract the AXValue from the first AXTextArea child.
    private static func firstTextAreaValue(in children: [AXUIElement]) -> String? {
        for child in children {
            if axRole(of: child) == kAXTextAreaRole as String {
                return axValue(of: child)
            }
        }
        return nil
    }

    // MARK: - AX Helpers

    private static func axChildren(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        )
        guard result == .success, let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    private static func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        )
        guard result == .success, let role = value as? String else {
            return nil
        }
        return role
    }

    private static func axValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        )
        guard result == .success, let text = value as? String else {
            return nil
        }
        return text
    }
}
