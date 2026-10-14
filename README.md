# Ode 🎙️

Hold-to-talk dictation for macOS powered by Claude Code CLI.

Speech is transcribed on-device with Whisper, then cleaned up by **the Claude Code you already have installed**: no API key, it uses your existing Claude plan. Want it even more accurate? Bring your own Deepgram key.

## 📦 Install

```bash
curl -fsSL https://raw.githubusercontent.com/jamiecurnow/ode/main/install.sh | bash
```

This installs to `/Applications` (or `~/Applications` on a non-admin account) and launches it. A setup window covers the microphone and accessibility permissions, your choice of key, and personalisation.

Or download `Ode.dmg` from [Releases](https://github.com/jamiecurnow/ode/releases/latest). It isn't notarised, so on first launch go to System Settings › Privacy & Security › **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Ode.app`.

## ✅ Requirements

- Claude Code, signed in
- macOS 26+ on Apple Silicon (for the on-device `SpeechAnalyzer` API)
- About 600 MB of disk for the Whisper model, downloaded on first launch

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
hold ⌥ → 🎤 live preview (Apple) → release → 🗣️ Whisper on your Mac → 🧠 claude -p (Haiku 5.5, your style guide) → 📋 pasted at your cursor
```

- **Transcription** is set under **Speech Recognition** in the menu (or the setup window):

  | | Where | Notes |
  |---|---|---|
  | **Whisper** (default) | On your Mac | Whisper large-v3-turbo through [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on the GPU, 5-bit quantised (574 MB, downloads once in the background). Runs on the whole clip when you let go, about 0.5s for a typical dictation. Apple's recogniser drives the live preview and fills in until the model is ready. |
  | **Apple** | On your Mac | macOS's `SpeechAnalyzer`. No download and slightly faster, but noticeably less accurate. |
  | **Deepgram** | Deepgram's servers | nova-3, streamed live with your own API key (stored in your Keychain, billed to your Deepgram account). The best with names and jargon, and the live preview is Deepgram's too. Final text is ready about 0.2s after you let go. If Deepgram fails, Ode uses Whisper and tells you why. |

  On a set of real dictations full of names and jargon, Apple got about 1 word in 6 wrong, Whisper 1 in 25 and Deepgram 1 in 20, with Deepgram spelling every name and product right. The comparison lives in `bench/` if you want to run it on your own voice.
- **Cleanup** sends the transcript text to Claude Haiku 5.5 (pinned, so it does not follow your CLI's `haiku` alias) through your local `claude` CLI. One idle `claude -p` process (stream-json, no tools or MCP, thinking off) is always kept ready, which brings cleanup to about 0.7s instead of a 2-4s cold start. Each dictation uses a fresh process, and each one is a small request against your plan's usage limits.
- **Style:** cleanup follows `~/Library/Application Support/Ode/style.md`. It removes filler, applies spoken corrections and matches how you write. It never answers or rewrites what you said.
- **Vocabulary:** the style guide's Vocabulary list biases speech recognition (Whisper's prompt, Deepgram's keyterms, Apple's contextual strings) and helps Claude fix misheard names.
- **Names:** lines like `Siobhan: Shivon, Chevonne` under the style guide's Names section are swapped in code after cleanup, in every app. Misheard names are the one thing Haiku can't fix reliably on its own.
- **Slack tags:** say "at Priya" in Slack and it becomes `@Priya`. Add `Priya: Priya Shah` under Slack names (Personalise fills these in from Slack) and Ode expands it to `@Priya Shah`.
- **App-aware:** Slack gets `:shortcodes:`, mail and docs get full sentences, everything else is casual.
- **Clipboard:** pastes with ⌘V, then restores the full previous clipboard. The temporary text is marked transient so clipboard managers skip it.
- **Fallbacks:** if Claude is slow or fails, the raw transcript is pasted and a short notice says why. If Ode can't paste, the text is left on the clipboard.
- **Sleep and stalls:** the mic and speech recogniser are rebuilt whenever your Mac wakes. If either gets stuck mid-dictation, Ode resets it after 10 seconds instead of ignoring the key until you restart it.
- **Privacy:** with Whisper or Apple, audio never leaves your Mac and only the transcript text does, through your own Claude Code. With Deepgram, your audio is streamed to Deepgram while you hold the key. The log (`~/Library/Logs/Ode.log`) records timings, not text.

## 🛠️ Development

A single SwiftPM executable. Its one dependency is whisper.cpp's prebuilt `whisper.xcframework`, which `build.sh` bundles into the app.

```bash
git clone https://github.com/jamiecurnow/ode && cd ode
./scripts/build.sh --install    # build, sign, install to /Applications, launch
```

Builds are signed with your Apple Development certificate if you have one, so permissions persist across rebuilds. Otherwise they're ad-hoc signed.

Test modes:

```bash
echo "um send me the the link" | build/Ode.app/Contents/MacOS/Ode --test-clean Slack   # cleanup + timings
echo "at Priya you around" | build/Ode.app/Contents/MacOS/Ode --test-clean Slack --runs 3   # flag lines that vary
build/Ode.app/Contents/MacOS/Ode --test-clean --suite                                 # saved cases in tests.txt
build/Ode.app/Contents/MacOS/Ode --test-transcribe file.aiff                          # Apple transcription ± vocabulary
build/Ode.app/Contents/MacOS/Ode --test-engines bench/clips                            # Whisper, and Deepgram streamed in real time
build/Ode.app/Contents/MacOS/Ode --test-overlay /tmp                                  # render overlay PNGs
```

| File | |
|---|---|
| `App.swift` | Menu bar, dictation flow, permissions |
| `Transcriber.swift` | Mic, recording, `SpeechAnalyzer` live preview, vocabulary |
| `WhisperEngine.swift` | whisper.cpp, model download |
| `Deepgram.swift` | Deepgram streaming, API key in the Keychain |
| `ClaudeCleaner.swift` | Warm `claude -p` process, stream-json |
| `StyleGuide.swift` | Cleanup rules, `style.md` |
| `Paster.swift` | Paste and clipboard restore |
| `AgentSession.swift` | Claude Code sessions for tuning |
| `SetupWindow.swift`, `Overlay.swift`, `HotkeyMonitor.swift` | UI and hotkey |

Pushing a `v*` tag builds and publishes `Ode.zip` and `Ode.dmg` via GitHub Actions.

---

MIT · Not affiliated with Anthropic.
