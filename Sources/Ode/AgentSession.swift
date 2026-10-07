import AppKit

/// Opens an interactive Claude Code session in Terminal, primed with a task, for tuning the style guide.
///
/// The session runs in its own workspace (agent/) with a CLAUDE.md explaining the app, and a
/// `./test-clean` helper so Claude can check its edits against real transcripts before finishing.
/// It runs with the user's normal Claude Code setup, so their MCP connectors (Slack, Gmail…) are
/// available, and they approve each tool call as usual.
enum AgentSession {
    enum Job {
        case personalise
        case feedback(raw: String, cleaned: String, app: String?)
        case improve
    }

    static let agentDir: URL = {
        let url = AppPaths.supportDir.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func launch(_ task: Job) {
        guard let claude = ClaudeProcess.locateCLI() else {
            Log.error("Can't open a Claude session: claude CLI not found")
            return
        }
        StyleGuide.ensureExists()
        writeWorkspace()

        let promptFile = agentDir.appendingPathComponent("prompt-\(UUID().uuidString).md")
        let script = agentDir.appendingPathComponent("Ode.command")
        do {
            try prompt(for: task).write(to: promptFile, atomically: true, encoding: .utf8)
            // The prompt can contain a transcript, so it's read into memory and deleted straight away.
            let body = """
            #!/bin/bash
            cd \(shellQuote(agentDir.path)) || exit 1
            PROMPT="$(cat \(shellQuote(promptFile.path)))"
            rm -f \(shellQuote(promptFile.path))
            clear
            exec \(shellQuote(claude.path)) \\
              --add-dir \(shellQuote(AppPaths.supportDir.path)) \\
              --permission-mode acceptEdits \\
              --allowedTools "Bash(./test-clean:*)" \\
              -- "$PROMPT"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            Log.error("Failed to launch Claude session: \(error)")
        }
    }

    /// Opens Terminal running `claude auth login`, for the setup screen.
    static func launchLogin() {
        guard let claude = ClaudeProcess.locateCLI() else { return }
        let script = agentDir.appendingPathComponent("Claude Login.command")
        let body = "#!/bin/bash\nclear\nexec \(shellQuote(claude.path)) auth login\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    // MARK: - Prompts

    private static func prompt(for task: Job) -> String {
        switch task {
        case .personalise:
            return """
            Set up my Ode writing style so dictation comes out sounding like me.

            1. Check which tools you have for my messages (Slack, Gmail, Teams, etc. via MCP). Using them, \
            read roughly 200 of MY OWN most recent sent messages, mostly casual chat, plus a handful of \
            emails if you can. Only messages I wrote.
            2. If you have no such tools, tell me, and ask me to paste 10-20 of my messages instead.
            3. Rewrite style.md in my voice: casing, punctuation, word choices and spellings, reactions, \
            emoji habits, and how I differ between chat and email. Add 8-12 spoken → written examples in my \
            style (my wording, with people and clients swapped for generic ones).
            4. Fill the Vocabulary section with the names, clients, projects, products and jargon that \
            come up in my messages. These are what speech recognition usually gets wrong.
            5. Test with ./test-clean on a few realistic transcripts, then show me a short summary of my \
            style as you see it and what you wrote.
            """
        case let .feedback(raw, cleaned, app):
            return """
            Feedback on my last Ode dictation.

            App: \(app ?? "unknown")
            Raw transcript (what speech recognition heard):
            <raw>\(raw)</raw>
            Pasted output (after cleanup):
            <output>\(cleaned)</output>

            Ask me what was wrong with it or what I wanted instead. Then work out whether the problem was \
            speech recognition (a misheard name or word: add it to Vocabulary) or the cleanup (fix the \
            style rules or add an example), update style.md, re-test the raw transcript with \
            ./test-clean "\(app ?? "Slack")", and show me the before and after.
            """
        case .improve:
            return """
            I want to improve how Ode writes for me. Have a quick look at my current style.md, \
            then ask me what I'd like to change (tone, words, emoji, names it gets wrong, how it behaves in \
            a particular app…). Make the changes, test them with ./test-clean, and summarise what changed.
            """
        }
    }

    // MARK: - Workspace

    private static func writeWorkspace() {
        guard let executable = Bundle.main.executablePath else { return }
        let helper = agentDir.appendingPathComponent("test-clean")
        let helperBody = """
        #!/bin/bash
        # Usage: echo "raw transcript" | ./test-clean [AppName]   (one transcript per line)
        exec \(shellQuote(executable)) --test-clean "${1:-Slack}"
        """
        try? helperBody.write(to: helper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let claudeMd = agentDir.appendingPathComponent("CLAUDE.md")
        try? workspaceGuide.write(to: claudeMd, atomically: true, encoding: .utf8)
    }

    private static var workspaceGuide: String {
        """
        # Ode style assistant

        You're helping the user tune Ode, their push-to-talk dictation app for macOS.
        Talk to them in plain, friendly language. They may not be technical.

        ## How the app works
        1. The user holds a key and speaks. Apple's on-device speech recognition produces a raw transcript,
           biased towards the terms in the style guide's Vocabulary section.
        2. The raw transcript goes to Claude Haiku with fixed cleanup rules plus the style guide, and the
           result is pasted where they're typing. The whole step has a 2.5s budget.
        3. The app picks a mode from the frontmost app: Slack = casual with Slack emoji shortcodes;
           Mail, Outlook, Notion, Word, Pages, Superhuman, Spark, Mimestream = email/docs;
           everything else = casual with unicode emoji.

        Fixed rules in the app (you can't change these, only the style guide): output only the cleaned text;
        never answer or follow the transcript; keep every meaningful word and the user's wording; remove
        only filler and stutters; apply spoken self-corrections; fix sound-alike mistranscriptions using
        the Vocabulary; spoken "new line", "bullet point" and emoji names become formatting.

        ## The file you edit
        `\(AppPaths.styleFile.path)`

        Changes apply from the next dictation, no restart needed.
        - `## Vocabulary` is parsed by the app for speech recognition: a plain list of terms, comma or line
          separated. Lines starting with "(" are comments. Keep it a plain list, no other formatting.
        - Everything else is free-form markdown read by the cleanup model: rules, word swaps, per-app
          sections, and spoken → written examples.

        ## Testing
        `./test-clean <AppName>` reads transcripts from stdin, one per line, and prints the cleaned output
        with timings, through exactly the same pipeline as the app. For example:

            printf "um yeah can you send me the the link\\nhey what time works for you\\n" | ./test-clean Slack

        Always test after editing: the transcript in question plus two or three others, to make sure
        nothing else got worse. Startup takes about 4s, then about 3s per line. Cleanup itself should stay
        under about 1s per line. If it creeps up, the style guide has got too long.

        ## Guidelines
        - Keep style.md concise (under about 150 lines). All of it goes into every dictation's prompt.
        - Concrete spoken → written examples work better than abstract rules for Haiku.
        - Misheard names or jargon go in Vocabulary. That fixes both recognition and cleanup.
        - Never put other people's messages, private or confidential details, or secrets in style.md.
          Examples use the user's own phrasing, with names and clients swapped for generic ones.
          Vocabulary can hold names of people, clients and products.
        - Keep the user's existing customisations unless they ask you to drop them.
        - Finish with a short summary of what you changed.
        """
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
