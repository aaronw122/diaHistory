# diaHistory — Building a Chat History Extractor for Dia Browser

## The Problem

Dia browser has a built-in AI assistant, but no way to export or save your chat history. Conversations disappear when you close them. If you want to reference something Dia told you last week, it's gone.

## Why Not Just Read the Data Directly?

Dia is closed-source. We explored every obvious path:

- **The DOM?** Dia's chat UI is native (Swift/AppKit), not web content. Opening DevTools shows the web page, but the chat panel isn't part of the DOM at all. Browser extensions can only touch web content, so they're useless here.
- **Dia's databases?** We found them — `assistant.db`, `chat_suggestions_database.db`, `skills_history_database.db` — all sitting in `~/Library/Application Support/Dia/User Data/Default/`. But they're encrypted. Standard SQLite tools can't open them.
- **AppleScript?** Dia has an AppleScript dictionary (`Dia.sdef`), and it exposes windows, tabs, and JavaScript execution. But no chat or assistant objects. Can't script what isn't exposed.

## The Accessibility Tree — Our Way In

macOS has an Accessibility API that lets you read the UI elements of any app. It's the same system VoiceOver uses for screen readers. Every button, text field, and label gets an accessibility role (`AXButton`, `AXTextArea`, `AXStaticText`, etc.) that describes what it is and what it contains.

We pointed this at Dia's chat panel and found everything:

- **User messages** show up as `AXGroup` elements containing an `AXImage` (the avatar) and an `AXTextArea` (the message text)
- **Assistant responses** are `AXGroup` elements with just an `AXTextArea`
- **Tool use actions** (like "Read file (2 times)") appear as `AXStaticText` elements

The text is complete — no truncation. We tested messages up to 935 characters and got every word back from the API.

We also confirmed there's no list virtualization. In a 5-exchange conversation, all 27 UI elements were present in the accessibility tree regardless of scroll position. The AX API returns everything, not just what's visible on screen.

## Running Automatically with a LaunchAgent

We didn't want a tool you have to remember to run. The goal is: install once, and every Dia conversation gets saved to `~/Documents/DiaChats/` automatically.

macOS LaunchAgents are user-level background services that start on login. Tools like yabai (tiling window manager) and skhd (hotkey daemon) use this exact pattern for accessibility-dependent daemons.

The one requirement: the user has to grant Accessibility permission in System Settings once. After that, the agent runs on every boot, watches Dia's conversation transcript via AXObserver, and appends new messages to markdown files.

We chose LaunchAgent over LaunchDaemon because daemons run as root before the GUI session exists — they can't access the accessibility tree or prompt for permissions.

## AXObserver over Polling — Let macOS Do the Work

The naive approach to a background daemon is polling: check the AX tree every few seconds, see if anything changed. But macOS offers something better — `AXObserver`.

AXObserver is event-driven. Instead of repeatedly asking "anything new?", we register a callback and macOS *tells us* when Dia's chat UI changes — a new message appeared, text was updated, children were added. Same concept as WebSockets vs. polling an API. Zero CPU cost when nothing is happening.

The important nuance: AXObserver only sends *notifications*, not the data itself. When it fires "children changed on this list," we still need to read the actual content using the same `AXUIElementCopyAttributeValue` calls. So AXObserver replaces the *when to check* part (event-driven instead of a timer loop), but the *how to read* part is identical either way.

We still use polling for two things: discovering whether Dia is running (every 30s) and finding a populated transcript (every 10s). This distinction matters. An open Dia chat with no messages yet exposes an empty-state shell in the accessibility tree, not the real transcript structure. We intentionally ignore that state. The tool only starts tracking once the first actual message appears and Dia creates the `AXScrollArea -> AXList -> AXList -> AXGroup...` subtree. Once that populated transcript exists, we hand off to AXObserver for the actual message capture. If AXObserver ever fails, we fall back to polling as a safety net.

## What Broke When We Actually Tested It

The entire codebase was built by parallel AI agents — 10 tasks across 4 buckets, each agent working in an isolated worktree. Every module compiled. Every PR passed review. And then we ran the binary against a real Dia instance and almost nothing worked correctly.

### Bug 1: Finding Obsidian Instead of Dia

The process finder matched any app with "dia" in the bundle ID. It found Obsidian first (`com.obsidian...` contains "dia"). The tool was confidently dumping Obsidian's accessibility tree and reporting "no capturable conversation found yet" — technically correct in spirit, just pointed at the wrong app entirely.

The plan spec said "look for bundle ID containing 'dia' or process name 'Dia'." A code review agent flagged the substring match as too broad. We dismissed it as "non-blocking" and merged anyway. Classic.

Fix: exact bundle ID match — `company.thebrowser.dia`.

### Bug 2: Every Message Created a New File

The daemon was supposed to update one file per conversation. Instead, every AXObserver notification triggered a full rewrite to a *new* file. The output directory filled with `whats-going-on.md`, `whats-going-on-2.md`, `whats-going-on-3.md`...

The MarkdownWriter's `write()` method generated a fresh filename every call, and the collision handler just appended incrementing numbers. The ChatWatcher had no concept of "this is the same conversation, write to the same file."

### Bug 3: The Conversation Tracker Was Never Wired In

This is the interesting one. Task 5 built the ChatWatcher (daemon loop). Task 6 built the ConversationTracker (fingerprinting, state persistence, file mapping). Both were in the same parallel bucket — two agents, working simultaneously, each in their own worktree.

The ConversationTracker was exactly the right solution: SHA256 fingerprint of the first user message, a JSON sidecar for state persistence, proper file identity tracking. But the ChatWatcher agent didn't know it existed. It couldn't — it was running in parallel, building against the same base branch. So the ChatWatcher invented its own conversation detection: compare message counts. If the count goes down, it's a new conversation.

During integration, we merged both branches, confirmed it compiled, and moved on. "It builds" was the only integration test. Nobody checked whether module A actually *used* module B.

This is a structural limitation of parallel agent execution: agents can build components that are *designed* to work together but *aren't connected*. The plan said "ConversationTracker handles identity" and "ChatWatcher handles the daemon loop." It never said "ChatWatcher must import and use ConversationTracker." Each agent followed its spec perfectly. The gap was between the specs.

### Bug 4: Non-Deterministic Window Selection

With multiple Dia tabs open, each with its own chat, `extractChatGroups()` walked all windows and returned the first match. Which window came first was non-deterministic. On one call it returned the Cloudflare conversation, on the next call the coding conversation. The daemon thought conversations were constantly switching, creating new files each time.

The fix required two things: extracting chat panels from *all* windows (not just the first), and routing each through ConversationTracker's fingerprinting so each conversation gets tracked independently with its own file.

### Bug 5: Stack Overflow in Deep Accessibility Trees

`findChatGroups()` did an unbounded recursive walk of the entire AX tree. Most of the time this was fine. But when it hit browser content trees — `AXWebArea` elements representing the actual web page DOM — it could descend 500+ frames deep and crash with `EXC_BAD_ACCESS` (stack overflow).

Fix: replaced the recursive traversal with a bounded iterative walk and added branch pruning to skip irrelevant subtrees (`AXWebArea`, menus). The chat panel lives at a known structural depth in Dia's UI hierarchy; there's no reason to dive into the rendered web content.

### Bug 6: Stale AX Elements During UI Rebuilds

When Dia rebuilds its chat UI — switching conversations, loading a new page — the AX tree is briefly invalid. Any `AXUIElementCopyAttributeValue` call on a stale element crashes with `BAD_ACCESS`. No error code, just a segfault.

The initial fix was a liveness pre-check: call `AXUIElementCopyAttributeNames` first, and only proceed if that succeeds. A Codex review rejected this. Both functions use the same Mach IPC under the hood, so `CopyAttributeNames` can crash for the exact same reason. Worse, it's a TOCTOU race — the element can go stale between the check and the read — and it doubles IPC overhead, widening the collision window.

The real fix: debounce after state transitions (100-200ms delay after AXObserver fires, letting Dia finish rebuilding), error-and-retry on individual element reads, and a depth limit to prevent runaway traversal.

### The Pattern

Every bug followed the same shape: the code was correct in isolation but wrong in integration. The process finder worked — just against the wrong app. The file writer worked — just created too many files. The conversation tracker worked — just wasn't connected. The window walker worked — just returned unstable results. The tree walker worked — until it hit a tree that was too deep or too stale.

Multi-agent development compiles clean and fails at the seams. The integration phase needs to verify *behavior*, not just *compilation*.

## Decisions Made

1. **Accessibility API over database extraction** — the databases are encrypted, the DOM doesn't contain the chat, and AppleScript doesn't expose it. The AX tree is the only viable read path.
2. **LaunchAgent for auto-start** — runs on login, one-time permission grant, restarts on crash. Same proven pattern as yabai/skhd.
3. **Markdown output with date subdirectories** — each conversation saved as `~/Documents/DiaChats/{date}/{slug}.md`. Originally a flat directory with `{date}_{slug}.md` filenames, but a power user capturing every conversation across multiple tabs could hit 10-20+ files per day. The flat directory would be unusable within weeks. Date-based subdirectories keep things browsable, and the slug drops the redundant date prefix.
4. **Tool use as annotations, not turns** — tool use actions like "Read file (2 times)" are buffered and prepended to the next assistant message as `[Read file (2 times)]` annotations, not emitted as separate conversational entries. Tool use is metadata about *how* Dia reached its answer, not a turn in the conversation. Separate entries would create phantom "messages" that break any downstream parsing expecting a clean user/assistant alternation.
5. **Content hash for change detection** — message count alone can't detect streaming updates, regenerations, or edits where the bubble count stays the same but the text changes. A SHA256 hash of all message content (role + text pairs) catches any change. The hash field is optional in the state file for backwards compatibility with existing installs.
6. **Page context metadata** — conversations now capture the domain and page title Dia was looking at. Extracted from the AX tree via window title, `AXDocument`, `AXURL`, and address-bar text fields. A merge-preserving strategy keeps metadata even if the user navigates away mid-conversation — once captured, it sticks. Dia doesn't always expose standard URL attributes, so a fallback scans for short text fields containing extractable domains.
7. **AXObserver at process level** — the observer is registered on Dia's entire application element, not a specific chat panel. Every UI event in Dia fires a notification — button hovers, scrolls, tooltips — but the content hash makes spurious triggers cheap. The alternative (registering on a specific panel) would miss events like new panels opening or panels being destroyed.
8. **Swift CLI** — native macOS accessibility APIs require Swift/ObjC. No bridging overhead, ships as a single binary.
9. **Ignore empty/open chats** — the daemon does not treat an empty chat shell as a conversation. It starts only when the first real message appears and Dia exposes a populated transcript.

## The Memory Leak We Didn't Think About

A week after shipping, the daemon was eating 1.2GB of compressed memory. RSS looked fine at ~12MB — the objects were retained but not actively accessed, so macOS compressed them. Classic slow leak that's invisible unless you check `footprint` or `vm_stat`.

We never thought about memory management because the daemon *felt* stateless. It polls, reads some text, writes a file, sleeps. What could accumulate?

Three things, it turned out:

### 1. The conversation state dictionary grew forever

`ConversationState.conversations` is a `[String: ConversationRecord]` dictionary — fingerprint to record — used for dedup so restarts don't create duplicate files. Every new conversation added an entry. Nothing ever removed one. The dict was serialized to disk on every save and held in memory for the process lifetime. After a week of active use, hundreds of entries with strings (file paths, previews, content hashes, metadata) piled up.

The fix we didn't think to build originally: eviction. We added a `lastUpdatedAt` timestamp to each record and prune anything inactive for more than 24 hours on every save. The markdown files on disk are the source of truth — the state dict is just a dedup cache. Evicting a stale entry doesn't lose data; worst case, returning to a very old conversation creates a new file.

We considered age-based eviction (drop records older than N days by creation date) but rejected it — a conversation *created* 30 days ago might still be *active* today, and evicting it would defeat the dedup purpose. LRU by last activity is the correct semantic.

### 2. Autorelease pools never drained

The polling loop runs forever: read the AX tree, process, sleep 5 seconds, repeat. Each iteration creates dozens of `AXUIElement` CF objects via `AXUIElementCopyAttributeValue`. These get autoreleased, but the `RunLoop.current.run(until:)` sleep doesn't necessarily drain the autorelease pool. Over days, the pool accumulates thousands of stale CF objects.

The fix is textbook: wrap each iteration in `autoreleasepool { }`. Same for the AXObserver callback, which is called from a C function and creates its own AX trees. Four lines of code, zero behavior change.

### 3. Regex compiled on every call

`extractDomain(from:)` created a new `NSRegularExpression` every invocation — called during metadata extraction on every polling cycle. Made it a `static let`. Trivial.

### The learning

When building a long-running daemon, you need to think about what accumulates. We focused on correctness — does it find the right process, parse the right elements, write the right files — and never asked "what happens to all the objects we create over a week of continuous operation?" Polling loops, dictionaries that only grow, CF interop without explicit pool management — none of these are bugs in a short-lived tool. They're only bugs when the process never exits.
