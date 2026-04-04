# diaHistory

A macOS CLI tool that automatically captures and archives your [Dia](https://dia.chat) browser conversations as local markdown or JSON files.

## Why

Dia conversations are ephemeral by default — once you close a tab, the context is gone. diaHistory gives you a persistent, searchable archive of everything you've discussed. With your conversations saved as plain markdown files, you can:

- **Build Anki cards** from concepts and patterns that came up in conversation
- **Revisit old insights** — that breakthrough explanation or learning session you half-remember is now grep-able
- **Track your learning over time** — work with Claude code and other tools to spot moments for growth

## Features

- **Real-time capture** — watches for Dia conversations using AXObserver with polling fallback
- **Markdown & JSON output** — readable markdown by default, structured JSON with `--json`
- **Page context metadata** — stores the active page title and domain when Dia exposes them
- **Conversation tracking** — fingerprints conversations by content hash to detect changes and avoid duplicates
- **Date-based organization** — files stored in `yyyy-MM-dd/` subdirectories with an auto-generated index
- **Daemon mode** — runs continuously in the background, surviving Dia restarts
- **LaunchAgent support** — auto-start on login with `--install`

## Requirements

- macOS 14.0 (Sonoma) or later
- [Dia browser](https://dia.chat) installed
- macOS Accessibility permission granted to diaHistory (you'll be prompted on first run)

## Installation

1. install via homebrew `brew install aaronw122/tap/diahistory`
2. Run `diahistory --install`.
3. If prompted, enable `diahistory` in **System Settings → Privacy & Security → Accessibility**.
4. Wait for `diahistory --install` to finish installing the LaunchAgent.

After that, diaHistory will start automatically on login and keep capturing in the background.

## Other commands

```bash
# Install with a custom output directory
diahistory --output ~/MyChats --install

# Use a different output directory for a foreground run
diahistory --output ~/MyChats
```

Conversations are saved to `~/Documents/DiaChats/` by default. Use `--output` to change this.
When you use `--install`, the current output directory is written into the
LaunchAgent plist. If you want to change the background agent's destination
later, rerun `diahistory --output <path> --install`.

## Advanced commands

```bash
# Run manually in the foreground instead of using the LaunchAgent
diahistory

# Dump Dia's accessibility tree for debugging
diahistory --debug-tree

# Enable verbose logging
diahistory --verbose
```

### Output structure

```
~/Documents/DiaChats/           # default output directory
├── index.md                    # table of all conversations
├── .diahistory-state.json      # internal tracking state
├── 2026-03-27/
│   ├── how-do-i-deploy-to.md
│   └── fix-the-login-bug.md
└── 2026-03-26/
    └── refactor-auth-module.md
```

### Markdown format

```markdown
# Dia Chat — 2026-03-27

**Page Title:** bootcamp-monorepo/curriculum
**Domain:** github.com

**You:**
Your message here

**Dia:**
Assistant response here
```

### JSON format

`--json` emits a conversation envelope with metadata plus messages. The
`metadata` key is always present; when page context is unavailable it is
`null`:

```json
{
  "metadata": {
    "pageTitle": "bootcamp-monorepo/curriculum",
    "domain": "github.com"
  },
  "messages": [
    {
      "role": "user",
      "text": "Your message here"
    }
  ]
}
```

## How it works

diaHistory uses the macOS Accessibility API (`AXUIElement`) to read Dia's chat transcript directly from the UI tree. It identifies user vs. assistant messages by their element structure, fingerprints conversations using SHA256 hashes, and performs atomic writes to prevent corruption.

The daemon runs a state machine:
1. **diaAbsent** — polls every 30s for the Dia process
2. **noChatOpen** — polls every 5s for an active chat panel
3. **watching** — monitors via AXObserver (falls back to polling if unavailable)

## Uninstall

```bash
# Remove the LaunchAgent if installed
diahistory --uninstall

# Uninstall via Homebrew
brew uninstall diahistory
brew untap aaronw122/tap
```

Your saved conversations in `~/Documents/DiaChats/` are not removed automatically.

## License

MIT
