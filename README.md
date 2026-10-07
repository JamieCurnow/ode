# Ode 🎙️

Hold-to-talk dictation for macOS powered by Claude Code CLI.

Speech is transcribed on-device, then cleaned up by **the Claude Code you already have installed**: no API key, it uses your existing Claude plan.

## 📦 Install

```bash
curl -fsSL https://raw.githubusercontent.com/jamiecurnow/ode/main/install.sh | bash
```

This installs to `~/Applications` and launches it. A setup window covers the microphone and accessibility permissions, your choice of key, and personalisation.

Or download `Ode.dmg` from [Releases](https://github.com/jamiecurnow/ode/releases/latest). It isn't notarised, so on first launch go to System Settings › Privacy & Security › **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Ode.app`.

## ✅ Requirements

- Claude Code, signed in
- macOS 26+ on Apple Silicon (for the on-device `SpeechAnalyzer` API)

## ⌨️ Usage

- Hold **Left Option** (configurable), speak, release.
- Pressing another key while holding cancels, so ⌥ shortcuts still work.
- Spoken formatting: "new line", "new paragraph", "bullet point", "thumbs up emoji". Self-corrections like "at 3, no sorry, 4pm" are applied.
- **Copy Last Raw Transcript** shows what the mic heard before cleanup.

## 🪄 Tuning your style

Ode uses Claude Code to edit its own style guide. Each option below opens an interactive `claude` session in Terminal:

| Menu item | What it does |
|---|---|
| **Setup & Personalise › Personalise** | Reads a sample of your own sent messages through your connected MCP tools (Slack, Gmail…) and writes your style guide and vocabulary. You approve each tool call. |
| **Feedback on Last Dictation…** | Shows Claude the raw and cleaned text. You say what was wrong; it updates the style guide and re-tests. |
| **Improve My Style with Claude…** | General changes. |
| **Edit Style Guide File…** | Edit `style.md` by hand. |

## 🧠 How it works

```
hold ⌥ → 🎤 on-device transcription (live preview) → 🧠 claude -p (Haiku, your style guide) → 📋 pasted at your cursor
```

- **Transcription** uses macOS's on-device `SpeechAnalyzer`, so audio never leaves your Mac. The OS manages the models, so there's nothing to download.
- **Cleanup** sends the transcript text to Claude Haiku through your local `claude` CLI. One idle `claude -p` process (stream-json, no tools or MCP, thinking off) is always kept ready, which brings cleanup to about 0.7s instead of a 2-4s cold start. Each dictation uses a fresh process, and each one is a small request against your plan's usage limits.
- **Style:** cleanup follows `~/Library/Application Support/Ode/style.md`. It removes filler, applies spoken corrections and matches how you write. It never answers or rewrites what you said.
- **Vocabulary:** the style guide's Vocabulary list biases speech recognition and helps Claude fix misheard names.
- **App-aware:** Slack gets `:shortcodes:`, mail and docs get full sentences, everything else is casual.
- **Clipboard:** pastes with ⌘V, then restores the full previous clipboard. The temporary text is marked transient so clipboard managers skip it.
- **Fallbacks:** if Claude is slow or fails, the raw transcript is pasted. If Ode can't paste, the text is left on the clipboard.
- **Privacy:** only the transcript text leaves your Mac, through your own Claude Code. The log (`~/Library/Logs/Ode.log`) records timings, not text.

## 🛠️ Development

A single SwiftPM executable with no dependencies.

```bash
git clone https://github.com/jamiecurnow/ode && cd ode
./scripts/build.sh --install    # build, sign, install to ~/Applications, launch
```

Builds are signed with your Apple Development certificate if you have one, so permissions persist across rebuilds. Otherwise they're ad-hoc signed.

Test modes:

```bash
echo "um send me the the link" | build/Ode.app/Contents/MacOS/Ode --test-clean Slack   # cleanup + timings
build/Ode.app/Contents/MacOS/Ode --test-transcribe file.aiff                          # transcription ± vocabulary
build/Ode.app/Contents/MacOS/Ode --test-overlay /tmp                                  # render overlay PNGs
```

| File | |
|---|---|
| `App.swift` | Menu bar, dictation flow, permissions |
| `Transcriber.swift` | `SpeechAnalyzer` / `DictationTranscriber`, vocabulary |
| `ClaudeCleaner.swift` | Warm `claude -p` process, stream-json |
| `StyleGuide.swift` | Cleanup rules, `style.md` |
| `Paster.swift` | Paste and clipboard restore |
| `AgentSession.swift` | Claude Code sessions for tuning |
| `SetupWindow.swift`, `Overlay.swift`, `HotkeyMonitor.swift` | UI and hotkey |

Pushing a `v*` tag builds and publishes `Ode.zip` and `Ode.dmg` via GitHub Actions.

---

MIT · Not affiliated with Anthropic.
