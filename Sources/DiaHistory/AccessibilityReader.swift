import Cocoa

/// Finds the Dia browser process and extracts chat AXGroup elements
/// from its accessibility tree.
struct AccessibilityReader {

    // MARK: - Public API

    /// Find the Dia process PID, or nil if not running.
    static func findDiaProcess() -> pid_t? {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            if let bundleID = app.bundleIdentifier,
               bundleID.localizedCaseInsensitiveContains("dia") {
                return app.processIdentifier
            }
            if let name = app.localizedName,
               name == "Dia" {
                return app.processIdentifier
            }
        }
        return nil
    }

    /// Extract chat AXGroup elements from Dia's accessibility tree.
    /// Returns nil if Dia isn't running or no chat panel is found.
    static func extractChatGroups() -> [AXUIElement]? {
        guard let pid = findDiaProcess() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)

        guard let windows = attribute(.windows, of: appElement) as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        // Search each window for the chat panel
        for window in windows {
            if let groups = findChatGroups(in: window) {
                return groups
            }
        }
        return nil
    }

    // MARK: - Tree Walking

    /// Walk the window looking for the chat panel structure:
    /// AXScrollArea → AXList → AXList with 3+ AXGroup children
    private static func findChatGroups(in element: AXUIElement) -> [AXUIElement]? {
        guard let children = attribute(.children, of: element) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            guard let role = attribute(.role, of: child) as? String else { continue }

            if role == kAXScrollAreaRole as String {
                if let groups = findChatListInScrollArea(child) {
                    return groups
                }
            }

            // Recurse into other containers
            if let groups = findChatGroups(in: child) {
                return groups
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
