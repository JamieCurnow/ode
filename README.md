# Ode 🎙️

**Hold a key. Talk. Let go. Your words land wherever you're typing, cleaned up by Claude and written the way *you* write.**

Ode is a tiny macOS menu bar app that gives you Claude Code's hold-to-talk voice input *everywhere*: Slack, email, your terminal, that Jira ticket you've been avoiding. It runs the cleanup through the [Claude Code](https://claude.com/claude-code) you already have installed, so there's no API key and no extra subscription. It just uses your Claude plan.

```
  hold ⌥ ──▶ 🎤 on-device speech-to-text ──▶ 🧠 Claude Haiku tidies it up ──▶ 📋 pasted where you're typing
              (live preview as you talk)        (in *your* style)              (clipboard restored after)
```

> "um yeah so I think we should uh probably move the the standup to like ten tomorrow"
>
> → `yeah so I think we should probably move the standup to 10 tomorrow`

## Install (30 seconds)

```bash
curl -fsSL https://raw.githubusercontent.com/jamiecurnow/ode/main/install.sh | bash
```

That drops `Ode.app` into `~/Applications`, launches it, and a setup window walks you through the rest (mic, accessibility, picking your key, and teaching it your style).

**You'll need:** an Apple Silicon Mac on **macOS 26+**, and [Claude Code](https://claude.com/claude-code) installed and logged in (`curl -fsSL https://claude.ai/install.sh | bash`, then run `claude` once).

<details>
<summary>Prefer a DMG?</summary>

Grab `Ode.dmg` from [Releases](https://github.com/jamiecurnow/ode/releases/latest) and drag Ode to Applications. It's not notarised (fun side project, no Apple tax), so the first time macOS will say it can't verify it. Go to **System Settings › Privacy & Security** and click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Ode.app
```
</details>

## What makes it nice

- **⚡️ Fast.** A Claude Code process is kept warm in the background (`claude -p` in stream-json mode, no tools, no MCP, thinking off), so cleanup is ~0.7s instead of the 2-4s cold start. Release-to-paste is about a second.
- **👀 Live preview.** A little pill shows your words as you speak, using macOS 26's on-device `SpeechAnalyzer`. No Whisper models to download, nothing to get randomly deleted.
- **🗣️ Sounds like you.** Cleanup follows *your* style guide: casing, slang, emoji habits, how you write in Slack vs email. It removes the ums and keeps your words.
- **🪄 Self-tuning, with Claude.** "Personalise" opens a Claude Code session that reads some of *your own* sent messages through *your* connected tools (Slack, Gmail…) and writes your style guide. "Feedback on Last Dictation" lets you say what it got wrong, and Claude fixes the style guide and re-tests it. Nobody touches code.
- **📖 Knows your words.** A Vocabulary list biases the speech recognition *and* tells Claude that "super base" means Supabase.
- **📋 Doesn't eat your clipboard.** Every clipboard type is snapshotted and restored after pasting, so your copied API key survives. The temporary text is marked transient so clipboard managers ignore it.
- **🧯 Fails gracefully.** Claude slow or offline? You get the raw transcript instead. Dictate a question? It gets cleaned up, not answered.
- **App-aware.** Slack gets `:shortcodes:`, Mail gets full sentences, everything else gets casual.

## Using it

| | |
|---|---|
| **Hold Left Option** (configurable) | Talk. Let go to paste. |
| Press another key while holding | Cancels, so ⌥-shortcuts still work |
| Menu bar ▸ **Feedback on Last Dictation…** | "It wrote X, I meant Y" → Claude fixes it |
| Menu bar ▸ **Improve My Style with Claude…** | General tweaks ("less emoji", "I never say 'gonna'") |
| Menu bar ▸ **Edit Style Guide File…** | Hand-edit `~/Library/Application Support/Ode/style.md` |
| Menu bar ▸ **Copy Last Raw Transcript** | See what the mic actually heard |

Spoken formatting works too: "new line", "new paragraph", "bullet point", "thumbs up emoji", and self-corrections like "at 3, no sorry, 4pm".

## Hacking on it

It's a single SwiftPM executable, about 1,900 lines of Swift, no dependencies.

```bash
git clone https://github.com/jamiecurnow/ode && cd ode
./scripts/build.sh --install     # build, sign, install to ~/Applications, launch
```

If you have an Apple Development certificate, the build script signs with it, so macOS remembers your permissions between rebuilds. Without one it ad-hoc signs and you'll re-grant mic and accessibility after each rebuild.

Handy test modes, no talking required:

```bash
# Run transcripts through the real cleanup pipeline (one per line), with timings
echo "um can you send me the the link" | build/Ode.app/Contents/MacOS/Ode --test-clean Slack

# Transcribe an audio file, with and without your Vocabulary
say -o /tmp/hi.aiff "deploy it to super base" && build/Ode.app/Contents/MacOS/Ode --test-transcribe /tmp/hi.aiff

# Render the overlay pill to PNGs
build/Ode.app/Contents/MacOS/Ode --test-overlay /tmp
```

| File | What lives there |
|---|---|
| `App.swift` | Menu bar, hold-to-talk flow, permissions |
| `Transcriber.swift` | `SpeechAnalyzer` + `DictationTranscriber`, live results, vocabulary biasing |
| `ClaudeCleaner.swift` | The warm `claude -p` process pool and stream-json plumbing |
| `StyleGuide.swift` | The cleanup rules + your `style.md` |
| `Paster.swift` | ⌘V with full clipboard snapshot/restore |
| `AgentSession.swift` | Launches the Personalise and Feedback Claude Code sessions |
| `SetupWindow.swift`, `Overlay.swift`, `HotkeyMonitor.swift` | The UI bits |

Releases: push a `v*` tag and GitHub Actions builds, packages (`Ode.zip` + `Ode.dmg`) and publishes the release.

## FAQ

**Does it cost anything?** Only your existing Claude plan. Each dictation is one small Haiku request, and it counts towards your plan's usage limits like any `claude -p` call.

**Where does my voice go?** Nowhere. Speech recognition is on-device. Only the *text* goes to Claude, via your own Claude Code. The log (`~/Library/Logs/Ode.log`) records timings, never your words.

**Why not just call the API?** Because then you'd need an API key and a second bill. Ode drives the official `claude` CLI and never touches your login tokens. Anthropic's rules on subscription use by third-party tools have changed a few times, so if that ever changes, a BYO-API-key option is the obvious next feature. PRs welcome.

**Why "Ode"?** A poem written to be spoken aloud. Also it's short, and nothing else on GitHub that does this was called it. 🎭

---

Not affiliated with Anthropic. Built in an afternoon by talking to Claude, which felt appropriate. MIT licensed.
