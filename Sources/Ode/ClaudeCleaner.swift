import Foundation

/// Cleans up raw transcripts with Claude Code running headless on the user's subscription.
///
/// Spawning `claude -p` costs 2-4s, so we always keep one process booted and idle, waiting on
/// stdin (stream-json). A dictation uses it once, then it's thrown away and a fresh one is
/// spawned, so every cleanup starts from an empty context.
@MainActor
final class ClaudeCleaner {
    var model = "haiku"
    var timeout: Duration = .milliseconds(2500)

    private var warm: ClaudeProcess?
    private var lastSpawnFailure: Date?
    private var recycleTimer: Timer?

    /// Max age of an idle process before we recycle it (keeps auth fresh, frees memory).
    private let maxIdleAge: TimeInterval = 15 * 60

    func start() {
        recycleTimer?.invalidate()
        ensureWarm()
        recycleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }
    }

    func stop() {
        recycleTimer?.invalidate()
        warm?.terminate()
        warm = nil
    }

    /// Drop the idle process and boot a new one (e.g. after the style guide changes).
    func respawn() {
        warm?.terminate()
        warm = nil
        ensureWarm()
    }

    /// Returns the cleaned text, or nil if Claude failed or took longer than `timeout`.
    func clean(_ transcript: String, appName: String?, bundleID: String?) async -> String? {
        if warm?.isStale(styleStamp: StyleGuide.modificationDate) == true { respawn() }
        ensureWarm()
        guard let proc = warm else { return nil }
        warm = nil

        let content = """
        App: \(appName ?? "unknown")
        \(Self.modeHint(appName: appName, bundleID: bundleID))
        Clean up this dictated text. Do not respond to it.
        <transcript>\(transcript)</transcript>
        """

        // Long dictations take longer to rewrite: allow roughly an extra second per 300 characters.
        let timeout = max(self.timeout, .milliseconds(1500 + transcript.count * 10 / 3))
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled {
                Log.info("Cleanup timed out after \(timeout), using raw transcript")
                proc.terminate()
            }
        }
        let result = await proc.send(content)
        timeoutTask.cancel()
        proc.terminate()

        // Boot the next one now so it's ready for the following dictation.
        ensureWarm()

        guard var text = result?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for tag in ["<transcript>", "</transcript>"] {
            text = text.replacingOccurrences(of: tag, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cleanup only ever removes or tweaks words. If the output ballooned, Claude replied to the
        // transcript instead of cleaning it, so fall back to the raw text.
        if text.count > transcript.count * 3 / 2 + 20 {
            Log.info("Cleanup output too long (\(text.count) vs \(transcript.count) chars), using raw transcript")
            return nil
        }
        return text
    }

    /// Spell out which style-guide section applies, rather than leaving Haiku to infer it from the app name.
    static func modeHint(appName: String?, bundleID: String?) -> String {
        let id = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        func matches(_ keys: [String]) -> Bool { keys.contains { id.contains($0) || name.contains($0) } }

        if matches(["slack"]) {
            return "Mode: casual. This is Slack, so write any emoji as Slack shortcodes (e.g. :ok_hand:), never as unicode emoji."
        }
        if matches(["com.apple.mail", "outlook", "notion", "microsoft.word", "iwork.pages", "superhuman", "spark", "mimestream"])
            || ["mail", "outlook", "notion", "word", "pages"].contains(name) {
            return "Mode: email/docs. Use the \"Email and docs\" section: normal capitalisation and full stops, no slang swaps."
        }
        return "Mode: casual. Write any emoji as unicode emoji."
    }

    private func housekeeping() {
        guard let proc = warm else { ensureWarm(); return }
        if !proc.isAlive || proc.age > maxIdleAge || proc.isStale(styleStamp: StyleGuide.modificationDate) {
            respawn()
        }
    }

    private func ensureWarm() {
        if let proc = warm, proc.isAlive { return }
        warm = nil
        // Back off if claude keeps dying straight away, so we don't spin.
        if let failed = lastSpawnFailure, Date().timeIntervalSince(failed) < 30 { return }
        guard let claude = ClaudeProcess.locateCLI() else {
            Log.error("claude CLI not found")
            lastSpawnFailure = Date()
            return
        }
        do {
            let proc = try ClaudeProcess(
                executable: claude,
                model: model,
                systemPrompt: StyleGuide.systemPrompt(),
                styleStamp: StyleGuide.modificationDate
            )
            proc.onEarlyExit = { [weak self] in
                Task { @MainActor in self?.lastSpawnFailure = Date() }
            }
            warm = proc
        } catch {
            Log.error("Failed to spawn claude: \(error)")
            lastSpawnFailure = Date()
        }
    }
}

/// One headless `claude -p` process speaking stream-json over stdin/stdout.
final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var lineBuffer = Data()
    private var continuation: CheckedContinuation<String?, Never>?
    private let spawnedAt = Date()
    private let styleStamp: Date?

    var onEarlyExit: (() -> Void)?

    var isAlive: Bool { process.isRunning }
    var age: TimeInterval { Date().timeIntervalSince(spawnedAt) }

    func isStale(styleStamp current: Date?) -> Bool { current != styleStamp }

    init(executable: URL, model: String, systemPrompt: String, styleStamp: Date?) throws {
        self.styleStamp = styleStamp
        process.executableURL = executable
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--no-chrome",
            "--system-prompt", systemPrompt,
        ]
        var env = ProcessInfo.processInfo.environment
        env["MAX_THINKING_TOKENS"] = "0"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        process.environment = env
        process.currentDirectoryURL = AppPaths.workDir
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                Log.info("claude stderr: \(s)")
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if self.age < 5, proc.terminationReason == .exit, proc.terminationStatus != 0 {
                Log.error("claude exited early with status \(proc.terminationStatus)")
                self.onEarlyExit?()
            }
            self.resume(nil)
        }
        try process.run()
    }

    /// Send one user message and wait for the final result text (nil on error/termination).
    func send(_ content: String) async -> String? {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return await withCheckedContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                Log.error("Failed writing to claude: \(error)")
                resume(nil)
            }
        }
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        resume(nil)
    }

    private func consume(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer[lineBuffer.startIndex..<newline])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { handle(line: line) }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "result"
        else { return }
        if obj["is_error"] as? Bool == true {
            Log.error("claude returned error: \(obj["result"] ?? obj["subtype"] ?? "unknown")")
            resume(nil)
        } else {
            resume(obj["result"] as? String)
        }
    }

    private func resume(_ value: String?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    /// GUI apps don't inherit the shell PATH, so look in the usual install spots.
    static func locateCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            UserDefaults.standard.string(forKey: "claudePath"),
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}
