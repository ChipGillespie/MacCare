# MacCare 2.0 — Native macOS System Health, Cleanup, Uninstaller & Malware Suite

**MacCare** is a lightweight (~2.7 MB), 100% native SwiftUI macOS utility designed as a transparent, zero-subscription alternative to commercial "Mac cleaner" subscriptions.

It performs **read-only diagnostics first**, never runs persistent background bloatware, and moves cleaned items safely to your **macOS Trash** so you always have a rollback path before emptying Trash.

---

## Features (8 Built-In Modules)

1. **Overview Dashboard**
   - Live SSD storage gauge, Battery Health (Maximum Capacity %, Cycle Count, Condition), Unified Memory breakdown, and top CPU/RAM processes.
2. **Cleanup & System Junk**
   - **AI Clutter & Intelligence Caches:** Apple Intelligence Flow caches, Visual Intelligence / Neural Engine E5 bundles, Google Gemini caches, Codex, Ollama (`~/.ollama`), and HuggingFace (`~/.cache/huggingface`).
   - **Developer & Xcode Caches:** `iOS DeviceSupport`, `CoreSimulator`, and `DerivedData`.
   - **System Junk, App Caches & Logs:** Homebrew download caches (`brew cleanup --prune=all`), Google/Chrome caches, GeoServices caches, Saved Application State, and User Logs.
   - **Mail & Messages Attachments:** Apple Mail downloaded attachments and iMessage media attachments.
   - **Trash Bins:** Inspect and empty `~/.Trash`.
3. **Large & Duplicate Files Finder**
   - **Large Files:** Scan `Downloads`, `Documents`, `Movies`, `Music`, `Pictures`, `Desktop`, and `Projects` with a configurable size filter (`> 10 MB`, `> 25 MB`, `> 100 MB`, `> 500 MB`).
   - **Exact Duplicates:** Fast two-pass size + `SHA-256` cryptographic fingerprint scanner that groups 100% identical files and automatically keeps the original unselected while selecting duplicate copies for safe removal.
4. **App Uninstaller (AppCleaner Style)**
   - Deep-scans any installed `.app` across `/Applications` and `~/Applications` to locate all associated `Application Support` folders, `Containers`, `Group Containers`, `Caches`, `Preferences (.plist)`, `Saved State`, `LaunchAgents`, `LaunchDaemons`, `PrivilegedHelperTools`, and `Receipts`.
   - Gracefully quits the app, unloads background daemons, and moves all selected items to Trash.
5. **App Updater & Version Checker**
   - Checks **Homebrew GUI Casks**, **Homebrew CLI Formulae**, and **Sparkle (`SUFeedURL`)** release feeds across `/Applications`, with 1-click update buttons.
6. **Malware Scanner (Apple XProtect YARA + Open-Source YARA + Codesign)**
   - Combines the open-source **YARA** engine (`/opt/homebrew/bin/yara`) with **Apple's official `XProtect.yara` & `XPScripts.yr` signatures** (580+ official Apple rules), **Community macOS Threat Intelligence YARA rules** (targeting modern macOS infostealers like AMOS, Poseidon, fake password prompts, and droppers), and **Apple Gatekeeper / `codesign` verification**.
   - Includes a **1-Click "Update Threat Definitions"** button to sync live cloud YARA feeds and verify XProtect updates.
7. **Security & Login Items Audit**
   - Verifies **System Integrity Protection (SIP)**, **Gatekeeper**, and **XProtect / XProtectPayloads** versions.
   - Lists all **macOS Login Items** and **Background `LaunchAgents` / `LaunchDaemons`** with 1-click **"Remove Login Item"** and **"Unload & Trash"** controls so apps can't sneakily persist in the background.
8. **Weekly Scheduled Background Scan**
   - Uses a standard macOS `LaunchAgent` (`--background-scan`) that consumes **0 MB RAM** during the week, runs at your chosen day/hour, and displays native macOS Notifications when the weekly check starts and finishes.

---

## Requirements

- **macOS 14.0 (Sonoma) or newer** (Apple Silicon M1/M2/M3/M4)
- **Xcode Command Line Tools** (`xcode-select --install`)
- *(Optional, for Malware Scanner & Brew Updater)* **Homebrew** + **YARA**:
  ```zsh
  brew install yara
  ```

---

## Build & Install in 10 Seconds

Clone the repository and run `./build_app.sh`:

```zsh
git clone https://github.com/ChipGillespie/MacCare.git
cd MacCare
chmod +x build_app.sh
./build_app.sh

# Install into /Applications and launch:
ditto build/MacCare.app /Applications/MacCare.app
open /Applications/MacCare.app
```

---

## Project Structure

```text
MacCare/
├── Info.plist
├── build_app.sh                  # Compiles the native SwiftUI .app bundle & generates AppIcon.icns
├── make_icon.swift               # CoreGraphics squircle icon generator
└── Sources/
    ├── MacCareApp.swift          # App entry point + --background-scan CLI handler
    ├── Models.swift              # Data models for all 8 modules
    ├── SystemScanner.swift       # Hardware, Battery, Caches, AI Clutter, Login Items & Schedule engine
    ├── AppUninstaller.swift      # Deep associated-file scanner & clean uninstaller
    ├── FileHunter.swift          # Large files & two-pass SHA-256 duplicate finder
    ├── AppUpdater.swift          # Homebrew Cask/Formula & Sparkle feed updater
    ├── MalwareScanner.swift      # YARA + Apple XProtect.yara + Community Threat Feed scanner
    └── ContentView.swift         # Native macOS SwiftUI NavigationSplitView interface
```

---

## License

MIT License — free to use, modify, and share.
