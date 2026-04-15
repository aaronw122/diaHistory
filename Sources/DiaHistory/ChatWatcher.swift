import ApplicationServices
import Cocoa
import Foundation

/// Daemon loop that monitors Dia for new chat messages once a populated
/// transcript exists.
///
/// Primary mechanism: AXObserver (event-driven) for change detection.
/// Falls back to polling for process/transcript discovery and when
/// AXObserver registration fails.
class ChatWatcher {

    enum State {
        case diaAbsent    // Dia process not found — poll every 30s
        case noChatOpen   // Dia running, no populated transcript — AXObserver + safety poll
        case watching     // AXObserver active (or polling fallback at 5s)
    }

    let outputDirectory: URL
    private(set) var state: State = .diaAbsent
    private var tracker: ConversationTracker
    private var writer: MarkdownWriter

    // AXObserver state
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedElement: AXUIElement?
    private var usingPollingFallback: Bool = false

    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        self.writer = try MarkdownWriter(outputDirectory: outputDirectory)
        self.tracker = try ConversationTracker(outputDirectory: outputDirectory)
    }

    // MARK: - Public API

    /// Start the watch loop. Blocks the current thread — runs via RunLoop.
    func start() {
        log("ChatWatcher starting, output: \(outputDirectory.path)")

        while true {
            autoreleasepool {
                let previousState = state

                switch state {
                case .diaAbsent:
                    pollForDia()

                case .noChatOpen:
                    // AXObserver should be active, but check liveness and
                    // transcript availability as a safety net.
                    checkNoChatOpen()

                case .watching:
                    if usingPollingFallback {
                        pollForChanges()
                    } else {
                        verifyDiaStillRunning()
                    }
                }

                // Skip sleep if state just changed — act on the new state immediately
                guard state == previousState else { return }

                switch state {
                case .diaAbsent:
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))
                case .noChatOpen, .watching:
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
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
            log("AXObserver registered on Dia")
        } else {
            log("AXObserver setup failed — will use polling fallback")
            usingPollingFallback = true
        }

        let captures = AccessibilityReader.extractAllChatCaptures()
        if !captures.isEmpty {
            log("Found \(captures.count) populated conversation transcript(s)")
            for capture in captures {
                handleCapture(capture)
            }
            transition(to: .watching)
        } else {
            transition(to: .noChatOpen)
        }
    }

    // MARK: - State: noChatOpen

    private func checkNoChatOpen() {
        guard AccessibilityReader.findDiaProcess() != nil else {
            teardownObserver()
            transition(to: .diaAbsent)
            return
        }

        let captures = AccessibilityReader.extractAllChatCaptures()
        if !captures.isEmpty {
            log("Conversation transcript detected (\(captures.count) panel(s))")
            for capture in captures {
                handleCapture(capture)
            }
            transition(to: .watching)
        }
    }

    // MARK: - State: watching

    private func pollForChanges() {
        guard AccessibilityReader.findDiaProcess() != nil else {
            teardownObserver()
            transition(to: .diaAbsent)
            return
        }

        let captures = AccessibilityReader.extractAllChatCaptures()
        if captures.isEmpty {
            transition(to: .noChatOpen)
            return
        }

        for capture in captures {
            handleCapture(capture)
        }
    }

    private func verifyDiaStillRunning() {
        guard let pid = AccessibilityReader.findDiaProcess() else {
            teardownObserver()
            transition(to: .diaAbsent)
            return
        }

        if pid != observedPid {
            Logger.warn("Dia PID changed (\(observedPid) -> \(pid)) — reconnecting")
            teardownObserver()
            transition(to: .diaAbsent)
        } else {
            // Process all panels — if none exist, go to noChatOpen
            let captures = AccessibilityReader.extractAllChatCaptures()
            if captures.isEmpty {
                transition(to: .noChatOpen)
            } else {
                for capture in captures {
                    handleCapture(capture)
                }
            }
        }
    }

    // MARK: - Core: handle groups via ConversationTracker

    /// Parse groups and delegate to ConversationTracker for identity + file management.
    private func handleCapture(_ capture: CapturedConversation) {
        let messages = ChatParser.parse(groups: capture.groups)
        guard !messages.isEmpty else { return }

        let result = tracker.track(messages: messages, metadata: capture.metadata)

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

    private func setupObserver(pid: pid_t) -> Bool {
        var obs: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &obs)
        guard result == .success, let obs = obs else {
            log("AXObserverCreate failed: \(result.rawValue)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        let notifications: [String] = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXCreatedNotification,
        ]

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
        self.usingPollingFallback = false

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
        usingPollingFallback = false
    }

    /// Called from the AXObserver C callback — re-extract and diff.
    fileprivate func handleAXNotification() {
        autoreleasepool {
            let captures = AccessibilityReader.extractAllChatCaptures()

            if captures.isEmpty {
                if state == .watching {
                    transition(to: .noChatOpen)
                }
                return
            }

            if state == .noChatOpen {
                log("Conversation transcript detected via AXObserver (\(captures.count) panel(s))")
            }

            for capture in captures {
                handleCapture(capture)
            }

            if state == .noChatOpen {
                transition(to: .watching)
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
    watcher.handleAXNotification()
}
