import ApplicationServices
import Cocoa
import Foundation

/// Daemon loop that monitors Dia for new chat messages.
///
/// Primary mechanism: AXObserver (event-driven) for change detection.
/// Falls back to polling for process/panel discovery and when
/// AXObserver registration fails.
class ChatWatcher {

    enum State {
        case diaAbsent    // Dia process not found — poll every 30s
        case noChatOpen   // Dia running, no chat panel — poll every 10s
        case watching     // AXObserver active (or polling fallback at 5s)
    }

    let outputDirectory: URL
    private(set) var state: State = .diaAbsent
    private var capturedMessages: [ChatMessage] = []
    private var writer: MarkdownWriter
    private var conversationDate: Date = Date()

    // AXObserver state
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedElement: AXUIElement?
    private var usingPollingFallback: Bool = false

    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        self.writer = try MarkdownWriter(outputDirectory: outputDirectory)
    }

    // MARK: - Public API

    /// Start the watch loop. Blocks the current thread — runs via RunLoop.
    func start() {
        log("ChatWatcher starting, output: \(outputDirectory.path)")

        while true {
            switch state {
            case .diaAbsent:
                pollForDia()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))

            case .noChatOpen:
                pollForChatPanel()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 10))

            case .watching:
                if usingPollingFallback {
                    pollForChanges()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
                } else {
                    // AXObserver is active — just run the loop briefly
                    // to let callbacks fire and check Dia is still alive
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
                    verifyDiaStillRunning()
                }
            }
        }
    }

    // MARK: - State: diaAbsent

    private func pollForDia() {
        guard let pid = AccessibilityReader.findDiaProcess() else {
            return // Stay in diaAbsent
        }
        log("Dia process found (pid \(pid))")
        transition(to: .noChatOpen)
    }

    // MARK: - State: noChatOpen

    private func pollForChatPanel() {
        // First verify Dia is still running
        guard let pid = AccessibilityReader.findDiaProcess() else {
            transition(to: .diaAbsent)
            return
        }

        guard let groups = AccessibilityReader.extractChatGroups() else {
            return // Stay in noChatOpen
        }

        log("Chat panel found with \(groups.count) groups")
        startWatching(pid: pid, groups: groups)
    }

    // MARK: - State: watching

    private func startWatching(pid: pid_t, groups: [AXUIElement]) {
        // Parse initial messages
        let messages = ChatParser.parse(groups: groups)
        capturedMessages = messages
        conversationDate = Date()

        if !messages.isEmpty {
            writeConversation()
        }

        // Try to set up AXObserver
        if setupObserver(pid: pid) {
            usingPollingFallback = false
            log("AXObserver registered — event-driven mode")
        } else {
            usingPollingFallback = true
            log("AXObserver setup failed — polling fallback (5s)")
        }

        transition(to: .watching)
    }

    private func pollForChanges() {
        guard AccessibilityReader.findDiaProcess() != nil else {
            teardownObserver()
            transition(to: .diaAbsent)
            return
        }

        guard let groups = AccessibilityReader.extractChatGroups() else {
            teardownObserver()
            transition(to: .noChatOpen)
            return
        }

        processGroups(groups)
    }

    private func verifyDiaStillRunning() {
        guard let pid = AccessibilityReader.findDiaProcess() else {
            teardownObserver()
            transition(to: .diaAbsent)
            return
        }

        // Also verify chat panel still exists
        if AccessibilityReader.extractChatGroups() == nil {
            teardownObserver()
            transition(to: .noChatOpen)
        } else if pid != observedPid {
            // Dia restarted with a new PID
            teardownObserver()
            transition(to: .noChatOpen)
        }
    }

    /// Compare new messages against captured state and append any new ones.
    private func processGroups(_ groups: [AXUIElement]) {
        let messages = ChatParser.parse(groups: groups)

        guard messages.count > capturedMessages.count else {
            // If message count decreased, a new conversation may have started
            if messages.count < capturedMessages.count && !messages.isEmpty {
                log("Message count decreased — new conversation detected")
                capturedMessages = messages
                conversationDate = Date()
                writeConversation()
            }
            return
        }

        // New messages appended
        let newMessages = Array(messages.dropFirst(capturedMessages.count))
        log("\(newMessages.count) new message(s) detected")
        capturedMessages = messages
        writeConversation()
    }

    private func writeConversation() {
        guard !capturedMessages.isEmpty else { return }
        do {
            let url = try writer.write(messages: capturedMessages, date: conversationDate)
            log("Wrote conversation to \(url.lastPathComponent)")
        } catch {
            log("Error writing conversation: \(error)")
        }
    }

    // MARK: - AXObserver

    private func setupObserver(pid: pid_t) -> Bool {
        var obs: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &obs)
        guard result == .success, let obs = obs else {
            log("AXObserverCreate failed: \(result.rawValue)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Register for value-changed and children-changed notifications on the app
        let notifications: [String] = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXCreatedNotification,
        ]

        // Pass self as context via Unmanaged pointer
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var registeredAny = false
        for notification in notifications {
            let addResult = AXObserverAddNotification(
                obs, appElement, notification as CFString, refcon
            )
            if addResult == .success || addResult == .notificationAlreadyRegistered {
                registeredAny = true
            }
        }

        guard registeredAny else {
            log("Failed to register any AX notifications")
            return false
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        self.observer = obs
        self.observedPid = pid
        self.observedElement = appElement

        return true
    }

    private func teardownObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        observer = nil
        observedElement = nil
        observedPid = 0
        capturedMessages = []
    }

    /// Called from the AXObserver C callback — re-extract and diff.
    fileprivate func handleAXNotification() {
        guard let groups = AccessibilityReader.extractChatGroups() else {
            // Chat panel disappeared
            teardownObserver()
            transition(to: .noChatOpen)
            return
        }
        processGroups(groups)
    }

    // MARK: - Helpers

    private func transition(to newState: State) {
        guard state != newState else { return }
        log("State: \(state) -> \(newState)")
        state = newState
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)] \(message)")
    }
}

// MARK: - AXObserver C Callback

/// Global callback function for AXObserver. Bridges to the ChatWatcher instance
/// via the refcon pointer.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<ChatWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleAXNotification()
}
