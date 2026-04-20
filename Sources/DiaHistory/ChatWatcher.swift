import ApplicationServices
import Cocoa
import Foundation

/// Daemon loop that monitors Dia for new chat messages.
///
/// Two-phase design:
/// - Discovery poll (15s): finds Dia's PID and populated chat panels
/// - Per-panel AXObserver: event-driven change detection on each panel's AXList
///
/// The discovery poll runs continuously to detect new panels, closed panels,
/// and Dia quitting. Per-panel observers provide instant message detection
/// between polls.
class ChatWatcher {

    enum State {
        case diaAbsent    // Dia process not found — poll every 30s
        case discovering  // Dia running — poll for panels every 15s, observers on found panels
    }

    /// A chat panel being actively observed for changes.
    private struct TrackedPanel {
        let handle: ChatPanelHandle
        var fingerprint: String
        var pollingFallback: Bool  // true if observer registration failed for this panel
    }

    let outputDirectory: URL
    private(set) var state: State = .diaAbsent
    private var tracker: ConversationTracker
    private var writer: MarkdownWriter

    // AXObserver — one shared observer per Dia PID
    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    // Per-panel tracking — keyed by CFHash of messageList
    private var trackedPanels: [UInt: TrackedPanel] = [:]

    // Debounce AX notifications: coalesce rapid-fire updates (e.g. streaming)
    // into a single re-read after a short delay.
    private var pendingNotifications: [UInt: Timer] = [:]
    private let debounceInterval: TimeInterval = 0.5

    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        self.writer = try MarkdownWriter(outputDirectory: outputDirectory)
        self.tracker = try ConversationTracker(outputDirectory: outputDirectory)
    }

    // MARK: - Public API

    /// Start the watch loop. Blocks the current thread — runs via RunLoop.
    ///
    /// In `diaAbsent`, polls every 30s for Dia's PID.
    /// In `discovering`, polls every 15s for panels. Per-panel AXObservers
    /// provide instant change detection between polls.
    func start() {
        log("ChatWatcher starting, output: \(outputDirectory.path)")

        // Prune stale state on launch and persist immediately
        tracker.pruneStaleConversations()
        try? tracker.save()

        // Schedule periodic pruning every 24 hours
        let pruneTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tracker.pruneStaleConversations()
            try? self.tracker.save()
        }
        pruneTimer.tolerance = 300  // 5 min tolerance for system scheduling efficiency
        RunLoop.current.add(pruneTimer, forMode: .common)

        while true {
            autoreleasepool {
                let previousState = state

                switch state {
                case .diaAbsent:
                    pollForDia()

                case .discovering:
                    discoverAndReconcile()
                }

                guard state == previousState else { return }

                switch state {
                case .diaAbsent:
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))
                case .discovering:
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 15))
                }
            }
        }
    }

    // MARK: - State: diaAbsent

    private func pollForDia() {
        guard let pid = AccessibilityReader.findDiaProcess() else {
            return
        }
        log("Dia process found (pid \(pid))")

        if setupObserver(pid: pid) {
            log("AXObserver created for Dia")
        } else {
            log("AXObserver creation failed — panels will use polling fallback")
        }

        observedPid = pid
        transition(to: .discovering)
    }

    // MARK: - State: discovering

    /// Poll for panels, register observers on new ones, tear down stale ones.
    private func discoverAndReconcile() {
        // Check Dia is still running
        guard let pid = AccessibilityReader.findDiaProcess() else {
            teardownAll()
            transition(to: .diaAbsent)
            return
        }

        // PID changed — Dia was restarted
        if pid != observedPid {
            Logger.warn("Dia PID changed (\(observedPid) -> \(pid)) — reconnecting")
            teardownAll()
            observedPid = pid
            if setupObserver(pid: pid) {
                log("AXObserver recreated for new Dia PID")
            }
        }

        // Discover all current panels
        let handles = AccessibilityReader.getAllPanelHandles()
        let currentKeys = Set(handles.map { CFHash($0.messageList) })
        let trackedKeys = Set(trackedPanels.keys)

        // Tear down panels that no longer exist
        for key in trackedKeys.subtracting(currentKeys) {
            if let panel = trackedPanels[key] {
                log("Panel gone: \(panel.fingerprint.prefix(8))...")
                unregisterPanelNotifications(panel)
                trackedPanels.removeValue(forKey: key)
            }
        }

        // Process each current panel
        for handle in handles {
            let key = CFHash(handle.messageList)
            let messages = ChatParser.parse(groups: handle.groups)
            guard !messages.isEmpty else { continue }

            let fingerprint = ConversationTracker.fingerprint(for: messages, domain: handle.metadata?.domain)

            if trackedPanels[key] == nil {
                // New panel — register observer and process
                var panel = TrackedPanel(
                    handle: handle,
                    fingerprint: fingerprint,
                    pollingFallback: observer == nil
                )

                if observer != nil {
                    let registered = registerPanelNotifications(handle)
                    panel.pollingFallback = !registered
                    if registered {
                        log("Observer registered on panel \(fingerprint.prefix(8))...")
                    }
                }

                trackedPanels[key] = panel
                handleMessages(messages, metadata: handle.metadata)
            } else {
                // Existing panel — process via poll (observer handles between polls)
                trackedPanels[key]?.fingerprint = fingerprint
                handleMessages(messages, metadata: handle.metadata)
            }
        }

        // Update active fingerprints for prune exemption
        let activeFingerprints = Set(trackedPanels.values.map(\.fingerprint))
        tracker.setActiveFingerprints(activeFingerprints)

        // Process panels using polling fallback
        for (key, panel) in trackedPanels where panel.pollingFallback {
            if let groups = AccessibilityReader.rereadGroups(from: panel.handle) {
                let messages = ChatParser.parse(groups: groups)
                guard !messages.isEmpty else { continue }
                handleMessages(messages, metadata: panel.handle.metadata)
            } else {
                // Stale element — remove, will be rediscovered next cycle
                log("Stale panel (polling fallback): \(panel.fingerprint.prefix(8))...")
                trackedPanels.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Core: handle messages via ConversationTracker

    private func handleMessages(_ messages: [ChatMessage], metadata: ConversationMetadata?) {
        let result = tracker.track(messages: messages, metadata: metadata)

        switch result {
        case .newConversation(let filePath, let createdAt, let metadata):
            log("New conversation: \(filePath.lastPathComponent)")
            writeMessages(messages, metadata: metadata, date: createdAt, to: filePath)
            saveState()

        case .existingConversation(let filePath, let createdAt, let metadata):
            writeMessages(messages, metadata: metadata, date: createdAt, to: filePath)
            saveState()

        case .noChange:
            break
        }
    }

    private func writeMessages(
        _ messages: [ChatMessage],
        metadata: ConversationMetadata?,
        date: Date,
        to fileURL: URL
    ) {
        do {
            try writer.write(messages: messages, metadata: metadata, date: date, to: fileURL)
            log("Updated \(fileURL.lastPathComponent) (\(messages.count) messages)")
        } catch {
            Logger.error("Failed to write: \(error.localizedDescription)")
        }
    }

    private func saveState() {
        do {
            try tracker.save()
            try tracker.updateIndex()
        } catch {
            Logger.error("Failed to save state: \(error.localizedDescription)")
        }
    }

    // MARK: - AXObserver

    /// Create a shared AXObserver for the Dia PID.
    /// Per-panel notification registrations are added separately.
    private func setupObserver(pid: pid_t) -> Bool {
        var obs: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &obs)
        guard result == .success, let obs = obs else {
            log("AXObserverCreate failed: \(result.rawValue)")
            return false
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        self.observer = obs
        return true
    }

    /// Register notifications on a specific panel's messageList element.
    /// Falls back to scrollArea if messageList rejects notifications.
    private func registerPanelNotifications(_ handle: ChatPanelHandle) -> Bool {
        guard let obs = observer else { return false }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let notifications: [String] = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXCreatedNotification,
        ]

        // Try messageList first
        var registered = false
        for notif in notifications {
            let r = AXObserverAddNotification(obs, handle.messageList, notif as CFString, refcon)
            if r == .success || r == .notificationAlreadyRegistered {
                registered = true
            }
        }
        if registered { return true }

        // Fall back to scrollArea
        for notif in notifications {
            let r = AXObserverAddNotification(obs, handle.scrollArea, notif as CFString, refcon)
            if r == .success || r == .notificationAlreadyRegistered {
                registered = true
            }
        }
        return registered
    }

    /// Remove notification registrations for a panel.
    private func unregisterPanelNotifications(_ panel: TrackedPanel) {
        guard let obs = observer else { return }

        let notifications: [String] = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXCreatedNotification,
        ]

        // Remove from both possible targets (safe to call even if not registered)
        for notif in notifications {
            AXObserverRemoveNotification(obs, panel.handle.messageList, notif as CFString)
            AXObserverRemoveNotification(obs, panel.handle.scrollArea, notif as CFString)
        }
    }

    private func teardownAll() {
        pendingNotifications.values.forEach { $0.invalidate() }
        pendingNotifications.removeAll()
        trackedPanels.removeAll()
        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        observer = nil
        observedPid = 0
    }

    /// Called from the AXObserver C callback.
    /// Debounces rapid notifications (e.g. streaming responses) into a single
    /// re-read after `debounceInterval` of quiet.
    fileprivate func handleAXNotification(element: AXUIElement, notification: CFString) {
        // Find which tracked panel this notification belongs to
        let matchedKey = trackedPanels.first(where: { _, panel in
            CFEqual(element, panel.handle.messageList) || CFEqual(element, panel.handle.scrollArea)
        })?.key

        guard let key = matchedKey else { return }

        // Cancel any pending timer for this panel and schedule a new one
        pendingNotifications[key]?.invalidate()
        pendingNotifications[key] = Timer.scheduledTimer(
            withTimeInterval: debounceInterval, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.pendingNotifications.removeValue(forKey: key)
            self.processPanel(key: key)
        }
    }

    /// Re-read a single panel's content and process changes.
    private func processPanel(key: UInt) {
        autoreleasepool {
            guard let panel = trackedPanels[key] else { return }

            if let groups = AccessibilityReader.rereadGroups(from: panel.handle) {
                let messages = ChatParser.parse(groups: groups)
                guard !messages.isEmpty else { return }
                handleMessages(messages, metadata: panel.handle.metadata)
            } else {
                // Element is stale — remove panel, discovery poll will handle it
                log("Stale panel detected via observer: \(panel.fingerprint.prefix(8))...")
                unregisterPanelNotifications(panel)
                trackedPanels.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Helpers

    private func transition(to newState: State) {
        guard state != newState else { return }
        log("State: \(state) -> \(newState)")
        state = newState
    }

    private func log(_ message: String) {
        Logger.info(message)
    }
}

// MARK: - AXObserver C Callback

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<ChatWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleAXNotification(element: element, notification: notification)
}
