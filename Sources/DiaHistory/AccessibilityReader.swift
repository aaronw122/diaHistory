import Cocoa

struct CapturedConversation {
    let groups: [AXUIElement]
    let metadata: ConversationMetadata?
}

/// Finds the Dia browser process and extracts capturable conversation
/// transcript AXGroup elements from its accessibility tree.
struct AccessibilityReader {
    private static let maxTraversalDepth = 64
    private static let maxTraversalNodes = 2_000
    private static let maxMetadataTraversalDepth = 6
    private static let maxMetadataTraversalNodes = 250
    private static let ignoredTraversalRoles: Set<String> = [
        "AXWebArea",
        kAXMenuBarRole as String,
        kAXMenuBarItemRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
    ]
    private static let metadataCandidateRoles: Set<String> = [
        kAXComboBoxRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
    ]

    // MARK: - Public API

    /// Find the Dia process PID, or nil if not running.
    static func findDiaProcess() -> pid_t? {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            if app.bundleIdentifier == "company.thebrowser.dia" {
                return app.processIdentifier
            }
        }
        return nil
    }

    /// Extract transcript groups plus page metadata from the first populated window.
    static func extractChatCapture() -> CapturedConversation? {
        guard let pid = findDiaProcess() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        let windows = discoverWindows(appElement)
        guard !windows.isEmpty else { return nil }

        for window in windows {
            if let capture = capture(in: window) {
                return capture
            }
        }

        return nil
    }

    /// Extract transcript AXGroup elements from Dia's accessibility tree.
    /// Returns nil if Dia isn't running or no populated transcript is found.
    static func extractChatGroups() -> [AXUIElement]? {
        extractChatCapture()?.groups
    }

    /// Extract transcript groups plus page metadata from all populated windows.
    static func extractAllChatCaptures() -> [CapturedConversation] {
        guard let pid = findDiaProcess() else { return [] }

        let appElement = AXUIElementCreateApplication(pid)
        let windows = discoverWindows(appElement)

        var captures: [CapturedConversation] = []
        for window in windows {
            if let capture = capture(in: window) {
                captures.append(capture)
            }
        }
        return captures
    }

    /// Extract transcript groups from ALL windows. Returns one array of groups per
    /// window that has a populated transcript. Empty array if none are found.
    static func extractAllChatGroups() -> [[AXUIElement]] {
        extractAllChatCaptures().map(\.groups)
    }

    // MARK: - Window Discovery

    /// Discover windows from Dia's AXApplication element.
    /// Prefers the standard AXWindows attribute but falls back to
    /// AXMainWindow / AXFocusedWindow when AXWindows is empty
    /// (a known Chromium-based browser quirk in some Dia versions).
    static func discoverWindows(_ appElement: AXUIElement) -> [AXUIElement] {
        if let windows = attribute(.windows, of: appElement) as? [AXUIElement], !windows.isEmpty {
            return windows
        }

        // Fallback: collect unique windows from AXMainWindow and AXFocusedWindow
        var windows: [AXUIElement] = []
        var seen = Set<UInt>()
        for attr: NSAccessibility.Attribute in [.mainWindow, .focusedWindow] {
            guard let raw = attribute(attr, of: appElement) else { continue }
            // AXMainWindow/AXFocusedWindow always return AXUIElement when non-nil.
            // Swift's `as?` doesn't work for CF type bridges, so force cast is correct here.
            let el = raw as! AXUIElement
            let hash = CFHash(el)
            if seen.insert(hash).inserted {
                windows.append(el)
            }
        }

        if !windows.isEmpty {
            Logger.debug("AXWindows empty — using AXMainWindow/AXFocusedWindow fallback (\(windows.count) window(s))")
        }

        return windows
    }

    // MARK: - Tree Walking

    private static func capture(in window: AXUIElement) -> CapturedConversation? {
        guard let groups = findChatGroups(in: window) else { return nil }
        return CapturedConversation(groups: groups, metadata: extractMetadata(from: window))
    }

    /// Walk the window looking for a populated transcript structure:
    /// AXScrollArea → AXList → AXList with 3+ AXGroup children.
    /// Empty/open chats are intentionally ignored until the first message appears.
    private static func findChatGroups(in root: AXUIElement) -> [AXUIElement]? {
        struct WorkItem {
            let element: AXUIElement
            let depth: Int
        }

        var stack = [WorkItem(element: root, depth: 0)]
        var visitedNodes = 0

        while let item = stack.popLast() {
            guard item.depth < maxTraversalDepth else { continue }
            guard let children = attribute(.children, of: item.element) as? [AXUIElement] else {
                continue
            }

            for child in children.reversed() {
                visitedNodes += 1
                guard visitedNodes <= maxTraversalNodes else { return nil }

                guard let role = attribute(.role, of: child) as? String else { continue }

                if role == kAXScrollAreaRole as String,
                   let groups = findChatListInScrollArea(child) {
                    return groups
                }

                guard !ignoredTraversalRoles.contains(role) else { continue }
                stack.append(WorkItem(element: child, depth: item.depth + 1))
            }
        }

        return nil
    }

    /// Inside a scroll area, look for AXList → AXList with 3+ AXGroup children.
    private static func findChatListInScrollArea(_ scrollArea: AXUIElement) -> [AXUIElement]? {
        guard let children = attribute(.children, of: scrollArea) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            guard let role = attribute(.role, of: child) as? String,
                  role == kAXListRole as String else { continue }

            // This is the outer AXList — look for inner AXList with AXGroup children
            if let groups = findGroupsInList(child) {
                return groups
            }
        }
        return nil
    }

    /// Inside an outer AXList, look for an inner AXList containing 3+ AXGroup children.
    private static func findGroupsInList(_ list: AXUIElement) -> [AXUIElement]? {
        guard let children = attribute(.children, of: list) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            guard let role = attribute(.role, of: child) as? String,
                  role == kAXListRole as String else { continue }

            // Inner AXList found — collect its AXGroup children
            guard let innerChildren = attribute(.children, of: child) as? [AXUIElement] else {
                continue
            }

            let groups = innerChildren.filter { element in
                guard let r = attribute(.role, of: element) as? String else { return false }
                return r == kAXGroupRole as String
            }

            if groups.count >= 3 {
                return groups
            }
        }
        return nil
    }

    // MARK: - AX Helpers

    /// Safely read a single attribute from an AXUIElement.
    /// Returns nil on any AXError.
    static func attribute(_ attr: NSAccessibility.Attribute, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr.rawValue as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    static func attribute(named attr: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    /// List all attribute names for an element (useful for debugging).
    static func attributeNames(of element: AXUIElement) -> [String]? {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names = names else { return nil }
        return names as? [String]
    }

    private static func extractMetadata(from window: AXUIElement) -> ConversationMetadata? {
        let pageTitle = normalizeString(attribute(.title, of: window) as? String)
        Logger.debug("Metadata: window title candidate = \(pageTitle ?? "<nil>")")

        var domainCandidates: [String] = []
        if let document = attribute(named: kAXDocumentAttribute as String, of: window) as? String {
            domainCandidates.append(document)
            Logger.debug("Metadata: AXDocument candidate = \(document)")
        }
        if let url = attribute(named: "AXURL", of: window) as? String {
            domainCandidates.append(url)
            Logger.debug("Metadata: AXURL candidate = \(url)")
        }
        let scannedCandidates = collectDomainCandidateStrings(in: window)
        domainCandidates.append(contentsOf: scannedCandidates)
        if !scannedCandidates.isEmpty {
            Logger.debug("Metadata: scanned candidates = \(scannedCandidates.joined(separator: " | "))")
        }

        let domain = domainCandidates.compactMap(ConversationMetadata.extractDomain(from:)).first
        Logger.debug("Metadata: resolved domain = \(domain ?? "<nil>")")
        let metadata = ConversationMetadata(pageTitle: pageTitle, domain: domain)
        if metadata.isEmpty {
            Logger.debug("Metadata: no usable page context extracted")
        }
        return metadata.isEmpty ? nil : metadata
    }

    private static func collectDomainCandidateStrings(in root: AXUIElement) -> [String] {
        struct WorkItem {
            let element: AXUIElement
            let depth: Int
        }

        var stack = [WorkItem(element: root, depth: 0)]
        var visitedNodes = 0
        var candidates: [String] = []

        while let item = stack.popLast() {
            guard item.depth < maxMetadataTraversalDepth else { continue }
            guard let children = attribute(.children, of: item.element) as? [AXUIElement] else {
                continue
            }

            for child in children.reversed() {
                visitedNodes += 1
                guard visitedNodes <= maxMetadataTraversalNodes else { return candidates }

                let role = attribute(.role, of: child) as? String ?? ""
                let title = normalizeString(attribute(.title, of: child) as? String)
                let description = normalizeString(attribute(.description, of: child) as? String)
                let value = normalizeString(attribute(.value, of: child) as? String)
                let hintText = [title, description]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()

                if metadataCandidateRoles.contains(role) {
                    let looksLikeAddressField =
                        hintText.contains("address") ||
                        hintText.contains("location") ||
                        hintText.contains("url")
                    let looksLikeDomainContext =
                        role == kAXTextAreaRole as String &&
                        value?.count ?? 0 <= 256 &&
                        ConversationMetadata.extractDomain(from: value) != nil

                    if let value,
                       looksLikeAddressField,
                       ConversationMetadata.extractDomain(from: value) != nil {
                        candidates.append(value)
                        Logger.debug("Metadata: accepted address-like candidate = \(value)")
                        if candidates.count >= 25 {
                            return candidates
                        }
                    } else if let value,
                              (role == kAXTextFieldRole as String || role == kAXComboBoxRole as String),
                              value.count <= 256,
                              (value.hasPrefix("http://") || value.hasPrefix("https://")),
                              ConversationMetadata.extractDomain(from: value) != nil {
                        candidates.append(value)
                        Logger.debug("Metadata: accepted URL candidate = \(value)")
                        if candidates.count >= 25 {
                            return candidates
                        }
                    } else if let value, looksLikeDomainContext {
                        candidates.append(value)
                        Logger.debug("Metadata: accepted domain-context candidate = \(value)")
                        if candidates.count >= 25 {
                            return candidates
                        }
                    }
                }

                guard !ignoredTraversalRoles.contains(role) else { continue }
                stack.append(WorkItem(element: child, depth: item.depth + 1))
            }
        }

        return candidates
    }

    private static func normalizeString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
