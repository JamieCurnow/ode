import AppKit
@preconcurrency import AVFoundation
import ServiceManagement
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        // Writing to a claude process that just died must not kill us.
        signal(SIGPIPE, SIG_IGN)
        if let i = CommandLine.arguments.firstIndex(of: "--test-transcribe"), CommandLine.arguments.indices.contains(i + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in
                let transcriber = Transcriber()
                for vocab in [false, true] {
                    let text = (try? await transcriber.transcribeFile(url, useVocabulary: vocab)) ?? "<error>"
                    print("\(vocab ? "with vocab" : "no vocab  "): \(text)")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-transcribe-dir"), CommandLine.arguments.indices.contains(i + 1) {
            // For bench/: every .wav in the folder, with and without vocabulary, as JSON lines on stdout.
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            Task { @MainActor in
                let transcriber = Transcriber()
                try? await transcriber.prepare()
                for clip in clips {
                    for vocab in [false, true] {
                        let start = Date()
                        let text = (try? await transcriber.transcribeFile(clip, useVocabulary: vocab)) ?? ""
                        let row: [String: Any] = [
                            "id": clip.deletingPathExtension().lastPathComponent,
                            "engine": vocab ? "apple+vocab" : "apple",
                            "text": text,
                            "ms": Int(Date().timeIntervalSince(start) * 1000),
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: row) {
                            print(String(decoding: data, as: UTF8.self))
                        }
                    }
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-engines"), CommandLine.arguments.indices.contains(i + 1) {
            // Runs .wav clips through Whisper, and through Deepgram streamed at real-time pace as if dictated,
            // timing each from the "release" (end of audio) like a real dictation. Prints JSON lines.
            let path = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let clips = path.pathExtension == "wav" ? [path]
                : ((try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            Task { @MainActor in
                await runEngineTest(clips)
                exit(0)
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--print-vocabulary") {
            StyleGuide.vocabulary().forEach { print($0) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-overlay"), CommandLine.arguments.indices.contains(i + 1) {
            // Renders the overlay pill with sample text to PNGs, for checking layout without dictating.
            let samples = [
                "Listening…",
                "hey man, what time's good for you",
                String(repeating: "Hello, we need to fix this little thing because it keeps breaking out of the box. ", count: 3),
                String(repeating: "This one is much longer and should be truncated at the start so the latest words stay visible. ", count: 8),
            ]
            for (n, text) in samples.enumerated() {
                let model = OverlayModel()
                model.text = n == 0 ? "" : text
                let renderer = ImageRenderer(content: OverlayView(model: model).background(Color.gray))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("overlay-\(n).png"))
                }
            }
            return
        }
        if CommandLine.arguments.contains("--test-clean") {
            runCleanupTest()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func runEngineTest(_ clips: [URL]) async {
        let vocabulary = StyleGuide.vocabulary()
        let whisper = WhisperEngine()
        whisper.prepare()
        while true {
            switch whisper.status {
            case .ready: break
            case let .failed(reason): print("Whisper unavailable: \(reason)")
            default:
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            break
        }
        // DEEPGRAM_API_KEY lets an unsigned test build skip the Keychain's "allow access" prompt.
        let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? DeepgramKey.read()
        if key == nil { print("No Deepgram key in the Keychain, skipping Deepgram") }
        func emit(_ clip: URL, _ engine: String, _ text: String?, _ start: Date) {
            let row: [String: Any] = [
                "id": clip.deletingPathExtension().lastPathComponent, "engine": engine,
                "text": text ?? "", "ms": Int(Date().timeIntervalSince(start) * 1000),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row) { print(String(decoding: data, as: UTF8.self)) }
        }
        for clip in clips {
            guard let samples = try? readSamples(clip) else { print("Couldn't read \(clip.lastPathComponent)"); continue }
            if whisper.isReady {
                let start = Date()
                let text = await whisper.transcribe(samples, vocabulary: vocabulary, language: SpeechEngine.languageCode)
                emit(clip, "ode-whisper", text, start)
            }
            if let key {
                let stream = DeepgramStream(key: key, vocabulary: vocabulary, language: "en")
                stream.start()
                let chunk = 1600 // 100 ms
                var offset = 0
                while offset < samples.count {
                    let end = min(offset + chunk, samples.count)
                    stream.send(Array(samples[offset..<end]))
                    offset = end
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let start = Date()
                let text = await stream.finish(timeout: 3)
                emit(clip, "ode-deepgram", text ?? "<\(stream.failure ?? "nothing heard")>", start)
            }
        }
        whisper.shutdown()
    }

    /// A .wav file as 16 kHz mono samples, the format dictation records in.
    private static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = Transcriber.recordingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format)
        else { throw OdeError.audioFormat }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw OdeError.audioFormat }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// `Ode --test-clean [app name] [--runs N]`: cleans each stdin line through the warm-process
    /// pipeline and prints timings, for tuning the style guide without dictating. With `--runs`, each
    /// line is cleaned N times and lines whose output varies are flagged.
    /// `Ode --test-clean --suite [--runs N]`: runs the saved cases in tests.txt and reports pass/fail.
    private static func runCleanupTest() {
        var args = Array(CommandLine.arguments.drop { $0 != "--test-clean" }.dropFirst())
        var runs = 1
        if let i = args.firstIndex(of: "--runs"), args.indices.contains(i + 1) {
            runs = max(1, Int(args[i + 1]) ?? 1)
            args.removeSubrange(i...(i + 1))
        }
        let suite = args.contains("--suite")
        let appName = args.first { !$0.hasPrefix("--") } ?? "Slack"

        let cases: [TestCase]
        if suite {
            cases = TestCase.load()
            if cases.isEmpty {
                print("No test cases yet. Add lines to \(AppPaths.testsFile.path) as: App | spoken | expected")
                exit(0)
            }
        } else {
            cases = AnyIterator { readLine() }.filter { !$0.isEmpty }.map { TestCase(app: appName, spoken: $0, expected: nil) }
        }

        Task { @MainActor in
            let cleaner = ClaudeCleaner()
            cleaner.start()
            try? await Task.sleep(for: .seconds(4))
            var failed = 0, varied = 0
            for test in cases {
                var outputs: [String] = []
                for _ in 0..<runs {
                    let start = Date()
                    let cleaned = await cleaner.clean(test.spoken, appName: test.app, bundleID: nil)
                    let out = StyleGuide.finish(cleaned ?? test.spoken, appName: test.app, bundleID: nil)
                    outputs.append(out)
                    let fallback = cleaned == nil ? "<fell back to raw: \(cleaner.lastFallbackReason ?? "unknown")> " : ""
                    let label = outputs.count == 1 ? "[\(test.app)] \(test.spoken)" : "  (run \(outputs.count))"
                    print(String(format: "[%4dms] %@\n         → %@", Int(Date().timeIntervalSince(start) * 1000), label, fallback + out))
                    try? await Task.sleep(for: .seconds(3))
                }
                if Set(outputs).count > 1 {
                    varied += 1
                    print("         ⚠︎ VARIES between runs")
                }
                if let expected = test.expected {
                    let misses = outputs.filter { $0 != expected }.count
                    if misses == 0 {
                        print("         ✓ PASS")
                    } else {
                        failed += 1
                        print("         ✗ FAIL (\(misses)/\(runs) runs), expected: \(expected)")
                    }
                }
                print("")
            }
            if suite { print("\(cases.count - failed)/\(cases.count) passed") }
            if runs > 1 { print("\(varied) of \(cases.count) lines varied across \(runs) runs") }
            cleaner.stop()
            exit(suite && failed > 0 ? 1 : 0)
        }
        RunLoop.main.run()
    }
}

/// One saved regression case from tests.txt: `App | spoken | expected`.
struct TestCase {
    let app: String
    let spoken: String
    let expected: String?

    static func load() -> [TestCase] {
        guard let text = try? String(contentsOf: AppPaths.testsFile, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.components(separatedBy: " | ")
            guard parts.count == 3 else { return nil }
            return TestCase(app: parts[0], spoken: parts[1], expected: parts[2])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, listening, processing }

    private var transcriber = Transcriber()
    private let whisper = WhisperEngine()
    /// The live Deepgram stream for the dictation in progress, when that engine is chosen.
    private var deepgram: DeepgramStream?
    /// The Mac woke mid-dictation: rebuild the speech pipeline once that dictation is done.
    private var resetPending = false
    private let cleaner = ClaudeCleaner()
    private let hotkeys = HotkeyMonitor()
    private let overlay = OverlayController()
    private let setup = SetupWindowController()
    private var statusItem: NSStatusItem!

    private var state: State = .idle
    private var startTask: Task<Void, Error>?
    private var pressedAt = Date()
    private var targetApp: NSRunningApplication?
    private var lastRaw = ""
    private var lastCleaned = ""
    private var lastAppName: String?

    private let defaults = UserDefaults.standard
    private var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanupEnabled") }
    }
    private var hotkey: Hotkey {
        get { Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .leftOption }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }
    private var speechEngine: SpeechEngine {
        get { SpeechEngine(rawValue: defaults.string(forKey: "speechEngine") ?? "") ?? .whisper }
        set { defaults.set(newValue.rawValue, forKey: "speechEngine") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Ode starting")
        StyleGuide.ensureExists()
        setUpStatusItem()
        setUpEditMenu()

        wireTranscriber()
        watchSleep()

        hotkeys.hotkey = hotkey
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.cancelDictation() }

        // First run: the setup screen walks through permissions instead of firing system prompts at launch.
        let firstRun = !defaults.bool(forKey: "setupComplete")
        watchPermissions(prompt: !firstRun)
        // Relaunched by Accessibility.requestAccess(): setup doesn't prompt at launch, so ask here.
        if Accessibility.consumeAskOnLaunch() && firstRun { Accessibility.ask() }
        hotkeys.start()
        if firstRun { showSetup() }
        if cleanupEnabled { cleaner.start() }

        prepareTranscriber()
        whisper.onStatusChange = { [weak self] status in self?.setup.update(whisperStatus: status) }
        // Whisper is also Deepgram's fallback, so only Apple-only skips the model.
        if speechEngine != .apple { whisper.prepare() }
        // Read the key now: a Keychain prompt mid-dictation would steal focus from the key press.
        if speechEngine == .deepgram { _ = DeepgramKey.read() }
    }

    private func wireTranscriber() {
        transcriber.onUpdate = { [weak self] text in
            guard let self, self.state == .listening else { return }
            // Deepgram's live text is better, so once it's talking, Apple's preview steps aside.
            if let deepgram = self.deepgram, !deepgram.transcript.isEmpty { return }
            if self.overlay.isVisible { self.overlay.update(text: text) }
        }
    }

    private func prepareTranscriber() {
        let transcriber = self.transcriber
        Task {
            do { try await transcriber.prepare() } catch {
                Log.error("Speech setup failed: \(error)")
                overlay.showError("Speech setup failed: \(error.localizedDescription)")
            }
        }
    }

    /// Swap in a fresh transcriber (new audio engine and speech analyzer). The old one may be stuck
    /// in a system call that never returns, so it's abandoned rather than waited for.
    private func resetTranscriber(_ reason: String) {
        Log.info("Resetting speech pipeline: \(reason)")
        transcriber.abandon()
        deepgram?.cancel()
        deepgram = nil
        transcriber = Transcriber()
        startTask = nil
        resetPending = false
        wireTranscriber()
        prepareTranscriber()
    }

    // MARK: - Sleep and wake

    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    /// Closing the lid mid-dictation would leave the mic and analyzer to sleep mid-stream, so drop it.
    private func systemWillSleep() {
        guard state == .listening else { return }
        Log.info("Mac going to sleep mid-dictation, cancelling it")
        cancelDictation()
    }

    /// Audio devices and the speech service can change under us while asleep, so start fresh on wake.
    private func systemDidWake() {
        // Re-arm the key monitors too, which also forgets a key press that never saw its release.
        hotkeys.start()
        if state == .listening { cancelDictation() }
        if state == .idle {
            resetTranscriber("woke from sleep")
        } else {
            Log.info("Woke from sleep mid-dictation, will reset the speech pipeline after it")
            resetPending = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaner.stop()
        whisper.shutdown()
    }

    // MARK: - Dictation flow

    /// Safety stop, in case a release is never seen at all.
    private let maxDictation: TimeInterval = 5 * 60

    private func hotkeyPressed() {
        guard state == .idle else {
            Log.info("Hotkey pressed while the last dictation is still \(state), ignored")
            return
        }

        // Don't start the mic until it's allowed: the permission dialog steals focus mid-press.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            overlay.showError("Allow microphone access, then hold the key again")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("Microphone access \(granted ? "granted" : "denied")")
            }
            return
        default:
            overlay.showError("Ode needs the microphone. Turn it on in System Settings › Privacy & Security › Microphone")
            return
        }

        state = .listening
        pressedAt = Date()
        targetApp = NSWorkspace.shared.frontmostApplication
        setStatusIcon(listening: true)

        startDeepgramIfChosen()

        // Start the mic straight away so the first word isn't lost, but only show the
        // overlay after a beat, so a quick ⌥-shortcut doesn't flash it.
        startTask = Task { try await transcriber.start() }
        let pressed = pressedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDictation) { [weak self] in
            guard let self, self.state == .listening, self.pressedAt == pressed else { return }
            Log.info("Dictation hit the \(Int(self.maxDictation))s limit, stopping")
            self.hotkeys.forceRelease()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.state == .listening else { return }
            self.overlay.show(.listening, text: self.transcriber.transcript)
        }
    }

    private func hotkeyReleased() {
        guard state == .listening else { return }
        state = .processing
        let heldFor = Date().timeIntervalSince(pressedAt)

        let start = startTask
        let transcriber = self.transcriber
        let stream = deepgram
        deepgram = nil
        Task {
            var usedStream = false
            defer {
                if !usedStream { stream?.cancel() }
                state = .idle
                setStatusIcon(listening: false)
                if resetPending { resetTranscriber("woke from sleep during the last dictation") }
            }
            do {
                guard try await withDeadline(stallLimit, { try await start?.value; return true }) != nil else {
                    recoverFromStall("starting the mic")
                    return
                }
            } catch {
                Log.error("Mic start failed: \(error)")
                overlay.showError("Couldn't start the mic: \(error.localizedDescription)")
                return
            }
            let releasedAt = Date()
            guard let appleText = try? await withDeadline(stallLimit, { await transcriber.stop() }) else {
                recoverFromStall("finishing the transcript")
                return
            }
            // Shorter taps are just ⌥ on its own, not dictation.
            guard heldFor > 0.3 else {
                overlay.hide()
                return
            }
            usedStream = true
            let heard = await finalTranscript(apple: appleText, samples: transcriber.recordedSamples, deepgram: stream)
            let raw = heard.text
            let transcribeMs = ms(since: releasedAt)

            guard !raw.isEmpty else {
                Log.info("Dictation: held \(String(format: "%.1f", heldFor))s, heard nothing")
                overlay.hide()
                return
            }
            lastRaw = raw
            lastAppName = targetApp?.localizedName
            overlay.update(text: raw)

            var output = raw
            var cleanMs = 0
            var fallbackReason: String?
            if cleanupEnabled {
                overlay.set(.cleaning)
                let cleanStart = Date()
                if let cleaned = await cleaner.clean(
                    raw,
                    appName: targetApp?.localizedName,
                    bundleID: targetApp?.bundleIdentifier
                ) {
                    output = cleaned
                } else {
                    fallbackReason = cleaner.lastFallbackReason ?? "cleanup failed"
                }
                cleanMs = ms(since: cleanStart)
            }
            output = StyleGuide.finish(output, appName: targetApp?.localizedName, bundleID: targetApp?.bundleIdentifier)
            lastCleaned = output
            overlay.hide()

            let pasteMs = ms(since: releasedAt)
            Log.info("Dictation: held \(String(format: "%.1f", heldFor))s, \(raw.count)→\(output.count) chars, "
                + "final transcript \(transcribeMs)ms (\(heard.source)), cleanup \(cleanMs)ms, release→paste \(pasteMs)ms")
            guard !output.isEmpty else { return }
            if AXIsProcessTrusted() {
                await Paster.paste(output)
                // So a rough paste isn't mistaken for the style guide not working.
                if let fallbackReason {
                    overlay.showNotice("Pasted as heard, without cleanup (\(fallbackReason))")
                } else if let notice = heard.notice {
                    overlay.showNotice(notice)
                }
            } else {
                // Without Accessibility, macOS silently drops our ⌘V. Hand the text over instead.
                copy(output)
                overlay.showError("Copied, press ⌘V to paste. To paste automatically, choose Ode menu › Open Accessibility Settings… and switch Ode on")
                Log.error("Accessibility not granted, left dictation on the clipboard instead of pasting")
            }
        }
    }

    private func cancelDictation() {
        guard state == .listening else { return }
        state = .idle
        deepgram?.cancel()
        deepgram = nil
        setStatusIcon(listening: false)
        overlay.hide()
        let start = startTask
        let transcriber = self.transcriber
        Task {
            // A start that failed has nothing to cancel, so only a start that never finishes counts here.
            guard (try? await withDeadline(stallLimit, { _ = try? await start?.value; return true })) != nil else {
                // Only reset if nothing has replaced it meanwhile (e.g. a wake reset).
                if transcriber === self.transcriber { resetTranscriber("starting the mic stalled while cancelling") }
                return
            }
            transcriber.cancel()
        }
    }

    // MARK: - Speech engines

    private func startDeepgramIfChosen() {
        guard speechEngine == .deepgram, let key = DeepgramKey.read(), !key.isEmpty else { return }
        let stream = DeepgramStream(
            key: key,
            vocabulary: StyleGuide.vocabulary(),
            language: SpeechEngine.languageCode == "en" ? "en" : "multi"
        )
        stream.onUpdate = { [weak self] text in
            guard let self, self.state == .listening, self.overlay.isVisible, !text.isEmpty else { return }
            self.overlay.update(text: text)
        }
        stream.start()
        transcriber.audioSink = { [weak stream] samples in stream?.send(samples) }
        deepgram = stream
    }

    /// The transcript to clean up: Deepgram's if it's streaming, else Whisper's, else Apple's.
    /// `notice` explains a fallback the user would want to know about (e.g. a rejected API key).
    private func finalTranscript(apple: String, samples: [Float], deepgram: DeepgramStream?) async
        -> (text: String, source: String, notice: String?) {
        var notice: String?
        if let deepgram {
            if let text = await deepgram.finish(timeout: 3) { return (text, "deepgram", nil) }
            guard let failure = deepgram.failure else {
                // Deepgram answered and heard nothing, so there's nothing to transcribe.
                return ("", "deepgram", nil)
            }
            Log.error("Deepgram failed (\(failure)), using on-device transcription")
            notice = "Deepgram didn't work (\(failure)), so this was transcribed on your Mac"
        }
        if speechEngine != .apple, whisper.isReady, Self.hasSpeech(samples) {
            // Whisper takes ~0.6s on a long dictation. If it's far slower than that, something's wrong.
            let limit = 3 + Double(samples.count) / 16000 * 0.2
            let vocabulary = StyleGuide.vocabulary()
            if let text = try? await withDeadline(limit, {
                await self.whisper.transcribe(samples, vocabulary: vocabulary, language: SpeechEngine.languageCode) ?? ""
            }), !text.isEmpty {
                return (text, "whisper", notice)
            }
            Log.info("Whisper gave nothing back within \(Int(limit))s, using Apple's transcript")
        }
        return (apple, "apple", notice)
    }

    /// Whisper invents text ("Thank you.") for silence, so only run it on audio that has some speech in it.
    /// On a MacBook mic, room noise sits around 0.0002 RMS and speech peaks at 0.015-0.04, so 90 ms above
    /// 0.003 means someone spoke, while a single click doesn't count.
    private static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = 480 // 30 ms at 16 kHz
        var loud = 0
        var start = 0
        while start + window <= samples.count {
            var sum: Float = 0
            for i in start..<(start + window) { sum += samples[i] * samples[i] }
            if (sum / Float(window)).squareRoot() > 0.003 { loud += 1 }
            if loud >= 3 { return true }
            start += window
        }
        return false
    }

    /// How long starting the mic or finishing a transcript may take before Ode treats it as stuck.
    /// Both normally take well under a second.
    private let stallLimit: TimeInterval = 10

    /// A speech or audio call never returned. Without this, Ode would sit in that dictation forever
    /// and ignore every later key press.
    private func recoverFromStall(_ step: String) {
        Log.error("Dictation stuck \(step) for \(Int(stallLimit))s")
        overlay.showError("Dictation got stuck, so Ode reset it. Hold the key to try again")
        resetTranscriber("stuck \(step)")
    }

    private func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    // MARK: - Permissions

    private func watchPermissions(prompt: Bool) {
        if prompt {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { Log.error("Microphone access denied") }
            }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.info("Waiting for Accessibility permission")
            // Global key monitors only start delivering once trusted, so re-arm when that happens.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                MainActor.assumeIsolated {
                    Log.info("Accessibility granted")
                    self?.hotkeys.start()
                }
            }
        }
    }

    // MARK: - Menu bar

    /// Menu-bar-only apps have no main menu, and without an Edit menu ⌘C/⌘V/⌘X/⌘A do nothing in
    /// our own text fields (including the setup screen's Try it box, which dictation pastes into).
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Ode", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(listening: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setStatusIcon(listening: Bool) {
        let name = listening ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ode")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let trusted = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let status = !trusted ? "Needs Accessibility permission"
            : !mic ? "Needs Microphone permission"
            : "Hold \(hotkey.title) to dictate"
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if !trusted {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        if !mic {
            menu.addItem(item("Open Microphone Settings…", #selector(openMicrophone)))
        }
        menu.addItem(.separator())

        let cleanup = item("Clean up with Claude", #selector(toggleCleanup))
        cleanup.state = cleanupEnabled ? .on : .off
        menu.addItem(cleanup)
        let feedback = item("Feedback on Last Dictation…", #selector(feedbackOnLast))
        feedback.isEnabled = !lastRaw.isEmpty
        menu.addItem(feedback)
        menu.addItem(item("Improve My Style with Claude…", #selector(improveStyle)))
        menu.addItem(item("Edit Style Guide File…", #selector(editStyle)))

        let hotkeyMenu = NSMenu()
        for key in Hotkey.allCases {
            let entry = item(key.title, #selector(chooseHotkey(_:)))
            entry.representedObject = key.rawValue
            entry.state = key == hotkey ? .on : .off
            hotkeyMenu.addItem(entry)
        }
        let hotkeyItem = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let engineMenu = NSMenu()
        for engine in SpeechEngine.allCases {
            let entry = item(engine.title, #selector(chooseEngine(_:)))
            entry.representedObject = engine.rawValue
            entry.state = engine == speechEngine ? .on : .off
            engineMenu.addItem(entry)
        }
        engineMenu.addItem(.separator())
        if speechEngine != .apple {
            let status = engineMenu.addItem(withTitle: whisperMenuStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            if case .failed = whisper.status { engineMenu.addItem(item("Retry Whisper Download", #selector(retryWhisper))) }
        }
        let hasKey = DeepgramKey.exists
        engineMenu.addItem(item(hasKey ? "Change Deepgram API Key…" : "Add Deepgram API Key…", #selector(setDeepgramKey)))
        if hasKey { engineMenu.addItem(item("Remove Deepgram API Key", #selector(removeDeepgramKey))) }
        let engineItem = NSMenuItem(title: "Speech Recognition", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        menu.addItem(.separator())
        let copyRaw = item("Copy Last Raw Transcript", #selector(copyLastRaw))
        copyRaw.isEnabled = !lastRaw.isEmpty
        menu.addItem(copyRaw)
        let copyClean = item("Copy Last Dictation", #selector(copyLastCleaned))
        copyClean.isEnabled = !lastCleaned.isEmpty
        menu.addItem(copyClean)

        menu.addItem(.separator())
        menu.addItem(item("Setup & Personalise…", #selector(openSetup)))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(item("Quit Ode", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        if cleanupEnabled { cleaner.start() } else { cleaner.stop() }
    }

    @objc private func feedbackOnLast() {
        AgentSession.launch(.feedback(raw: lastRaw, cleaned: lastCleaned, app: lastAppName))
    }

    @objc private func improveStyle() { AgentSession.launch(.improve) }

    @objc private func openSetup() { showSetup() }

    private func showSetup() {
        setup.show(
            hotkey: hotkey,
            engine: speechEngine,
            whisperStatus: whisper.status,
            onHotkeyChange: { [weak self] key in
                guard let self else { return }
                self.hotkey = key
                self.hotkeys.hotkey = key
                self.hotkeys.start()
            },
            onEngineChange: { [weak self] engine in self?.choose(engine) },
            onSetDeepgramKey: { [weak self] in self?.askForDeepgramKey() },
            onDone: { [weak self] in self?.defaults.set(true, forKey: "setupComplete") }
        )
    }

    @objc private func editStyle() {
        StyleGuide.ensureExists()
        NSWorkspace.shared.open(AppPaths.styleFile)
    }

    private var whisperMenuStatus: String {
        switch whisper.status {
        case .idle: "Whisper: not loaded"
        case let .downloading(fraction): "Whisper: downloading \(Int(fraction * 100))% of \(WhisperEngine.modelSize)"
        case .loading: "Whisper: loading…"
        case .ready: "Whisper: ready"
        case let .failed(reason): "Whisper: \(reason)"
        }
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = SpeechEngine(rawValue: raw) else { return }
        choose(engine)
    }

    private func choose(_ engine: SpeechEngine) {
        if engine == .deepgram, !DeepgramKey.exists {
            // Only switch once there's a key to use.
            askForDeepgramKey(thenUse: true)
            setup.update(engine: speechEngine)
            return
        }
        speechEngine = engine
        Log.info("Speech recognition: \(engine.rawValue)")
        // Whisper backs up Deepgram too; Apple-only frees the model's memory.
        if engine == .apple { whisper.unload() } else { whisper.prepare() }
        setup.update(engine: engine)
    }

    @objc private func retryWhisper() { whisper.prepare() }

    @objc private func setDeepgramKey() { askForDeepgramKey() }

    @objc private func removeDeepgramKey() {
        DeepgramKey.delete()
        if speechEngine == .deepgram { choose(.whisper) }
        setup.update(engine: speechEngine)
    }

    /// Asks for a Deepgram key, checks it with Deepgram, and saves it to the Keychain.
    private func askForDeepgramKey(thenUse: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Deepgram API Key"
        alert.informativeText = "Ode streams your audio to Deepgram while you hold the key, for the most accurate "
            + "transcription. Usage is billed to your Deepgram account. Create a key at console.deepgram.com. "
            + "It's stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Paste your API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            switch await DeepgramKey.validate(key) {
            case false:
                showAlert("Deepgram didn't accept that key", "Check you copied the whole key from console.deepgram.com, then try again.")
                return
            case nil:
                // Offline: save it anyway, a bad key falls back to on-device transcription with a notice.
                Log.info("Couldn't reach Deepgram to check the API key, saved it anyway")
            case true:
                break
            }
            guard DeepgramKey.save(key) else {
                showAlert("Couldn't save the key", "Ode couldn't write to your Keychain.")
                return
            }
            Log.info("Deepgram API key saved")
            if thenUse || speechEngine == .deepgram { choose(.deepgram) }
            setup.update(engine: speechEngine)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey(rawValue: raw) else { return }
        hotkey = key
        hotkeys.hotkey = key
        hotkeys.start()
    }

    @objc private func copyLastRaw() { copy(lastRaw) }
    @objc private func copyLastCleaned() { copy(lastCleaned) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.error("Launch at login: \(error)")
        }
    }

    @objc private func openAccessibility() {
        Accessibility.requestAccess()
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func showLog() { NSWorkspace.shared.open(AppPaths.logFile) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Runs `operation`, but gives up after `seconds` and returns nil without waiting for it to finish.
/// A task group can't do this: it always waits for its children, and some system calls never return.
@MainActor
func withDeadline<T>(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
    let once = DeadlineFlag()
    return try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
            do {
                let value = try await operation()
                if !once.done { once.done = true; continuation.resume(returning: value) }
            } catch {
                if !once.done { once.done = true; continuation.resume(throwing: error) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                if !once.done { once.done = true; continuation.resume(returning: nil) }
            }
        }
    }
}

private final class DeadlineFlag { var done = false }
