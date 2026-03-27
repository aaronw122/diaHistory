import Cocoa

/// Finds the Dia browser process and extracts capturable conversation
/// transcript AXGroup elements from its accessibility tree.
struct AccessibilityReader {
    private static let maxTraversalDepth = 64
    private static let maxTraversalNodes = 2_000
    private static let ignoredTraversalRoles: Set<String> = [
        "AXWebArea",
        kAXMenuBarRole as String,
        kAXMenuBarItemRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
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

    /// Extract transcript AXGroup elements from Dia's accessibility tree.
    /// Returns nil if Dia isn't running or no populated transcript is found.
    static func extractChatGroups() -> [AXUIElement]? {
        guard let pid = findDiaProcess() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)

        guard let windows = attribute(.windows, of: appElement) as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        // Return the first populated transcript found (for --once and backwards compat).
        // Use extractAllChatGroups() for multi-conversation capture.
        for window in windows {
            if let groups = findChatGroups(in: window) {
                return groups
            }
        }
        return nil
    }

    /// Extract transcript groups from ALL windows. Returns one array of groups per
    /// window that has a populated transcript. Empty array if none are found.
    static func extractAllChatGroups() -> [[AXUIElement]] {
        guard let pid = findDiaProcess() else { return [] }

        let appElement = AXUIElementCreateApplication(pid)

        guard let windows = attribute(.windows, of: appElement) as? [AXUIElement],
              !windows.isEmpty else {
            return []
        }

        var allGroups: [[AXUIElement]] = []
        for window in windows {
            if let groups = findChatGroups(in: window) {
                allGroups.append(groups)
            }
        }
        return allGroups
    }

    // MARK: - Tree Walking

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

    /// List all attribute names for an element (useful for debugging).
    static func attributeNames(of element: AXUIElement) -> [String]? {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names = names else { return nil }
        return names as? [String]
    }
}
