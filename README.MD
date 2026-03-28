# diaHistory

A macOS CLI tool that automatically captures and archives your [Dia](https://dia.chat) browser conversations as local markdown or JSON files.

## Features

- **Real-time capture** — watches for Dia conversations using AXObserver with polling fallback
- **Markdown & JSON output** — readable markdown by default, structured JSON with `--json`
- **Conversation tracking** — fingerprints conversations by content hash to detect changes and avoid duplicates
- **Date-based organization** — files stored in `yyyy-MM-dd/` subdirectories with an auto-generated index
- **Daemon mode** — runs continuously in the background, surviving Dia restarts
- **LaunchAgent support** — auto-start on login with `--install`

## Requirements

- macOS 14.0 (Sonoma) or later
- [Dia browser](https://dia.chat) installed
- macOS Accessibility permission granted to diaHistory (you'll be prompted on first run)

## Installation

### Homebrew (recommended)

```bash
brew install aaronw122/tap/diahistory
```

### Build from source

```bash
git clone https://github.com/aaronw122/diaHistory.git
cd diaHistory
make build
```

The binary will be at `.build/release/diahistory`. Move it somewhere on your `$PATH`:

```bash
cp .build/release/diahistory /usr/local/bin/
```

## Setup

On first run, diaHistory needs macOS Accessibility permission to read Dia's UI:

1. Run `diahistory` — it will prompt you if permission is missing
2. Open **System Settings → Privacy & Security → Accessibility**
3. Add and enable `diahistory` (or your terminal app if running from source)
4. Run `diahistory` again

## Usage

```bash
# Run in daemon mode (watches continuously)
diahistory

# Capture current conversation and exit
diahistory --once

# Output as JSON instead of markdown
diahistory --json

# Custom output directory
diahistory --output ~/MyChats

# Auto-start on login (installs LaunchAgent)
diahistory --install

# Remove auto-start
diahistory --uninstall

# Debug: dump Dia's accessibility tree
diahistory --debug-tree

# Verbose logging
diahistory --verbose
```

Conversations are saved to `~/Documents/DiaChats/` by default. Use `--output` to change this.

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

**You:**
Your message here

**Dia:**
Assistant response here
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
