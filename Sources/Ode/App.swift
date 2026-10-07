import AppKit
import AVFoundation
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

    /// `Ode --test-clean [app name]`: cleans each stdin line through the warm-process
    /// pipeline and prints timings, for tuning the style guide without dictating.
    private static func runCleanupTest() {
        let args = CommandLine.arguments
        let appName = args.firstIndex(of: "--test-clean").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "Slack"
        let lines = AnyIterator { readLine() }.filter { !$0.isEmpty }
        Task { @MainActor in
            let cleaner = ClaudeCleaner()
            cleaner.start()
            try? await Task.sleep(for: .seconds(4))
            for line in lines {
                let start = Date()
                let out = await cleaner.clean(line, appName: appName, bundleID: nil) ?? "<nil: fell back to raw>"
                print(String(format: "[%4dms] %@\n         → %@", Int(Date().timeIntervalSince(start) * 1000), line, out))
                try? await Task.sleep(for: .seconds(3))
            }
            cleaner.stop()
            exit(0)
        }
        RunLoop.main.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, listening, processing }

    private let transcriber = Transcriber()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Ode starting")
        StyleGuide.ensureExists()
        setUpStatusItem()

        transcriber.onUpdate = { [weak self] text in
            guard let self, self.state == .listening else { return }
            if self.overlay.isVisible { self.overlay.update(text: text) }
        }

        hotkeys.hotkey = hotkey
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.cancelDictation() }

        // First run: the setup screen walks through permissions instead of firing system prompts at launch.
        let firstRun = !defaults.bool(forKey: "setupComplete")
        watchPermissions(prompt: !firstRun)
        hotkeys.start()
        if firstRun { showSetup() }
        if cleanupEnabled { cleaner.start() }

        Task {
            do { try await transcriber.prepare() } catch {
                Log.error("Speech setup failed: \(error)")
                overlay.showError("Speech setup failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaner.stop()
    }

    // MARK: - Dictation flow

    /// Safety stop, in case a release is never seen at all.
    private let maxDictation: TimeInterval = 5 * 60

    private func hotkeyPressed() {
        guard state == .idle else { return }

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

        Task {
            defer {
                state = .idle
                setStatusIcon(listening: false)
            }
            do {
                try await startTask?.value
            } catch {
                Log.error("Mic start failed: \(error)")
                overlay.showError("Couldn't start the mic: \(error.localizedDescription)")
                return
            }
            let releasedAt = Date()
            let raw = await transcriber.stop()
            let transcribeMs = ms(since: releasedAt)

            guard heldFor > 0.3, !raw.isEmpty else {
                overlay.hide()
                return
            }
            lastRaw = raw
            lastAppName = targetApp?.localizedName
            overlay.update(text: raw)

            var output = raw
            var cleanMs = 0
            if cleanupEnabled {
                overlay.set(.cleaning)
                let cleanStart = Date()
                if let cleaned = await cleaner.clean(
                    raw,
                    appName: targetApp?.localizedName,
                    bundleID: targetApp?.bundleIdentifier
                ) {
                    output = cleaned
                }
                cleanMs = ms(since: cleanStart)
            }
            lastCleaned = output
            overlay.hide()

            let pasteMs = ms(since: releasedAt)
            Log.info("Dictation: held \(String(format: "%.1f", heldFor))s, \(raw.count)→\(output.count) chars, "
                + "final transcript \(transcribeMs)ms, cleanup \(cleanMs)ms, release→paste \(pasteMs)ms")
            guard !output.isEmpty else { return }
            if AXIsProcessTrusted() {
                await Paster.paste(output)
            } else {
                // Without Accessibility, macOS silently drops our ⌘V. Hand the text over instead.
                copy(output)
                overlay.showError("Copied, press ⌘V to paste. Turn on Ode in Settings › Privacy & Security › Accessibility to paste automatically")
                Log.error("Accessibility not granted, left dictation on the clipboard instead of pasting")
            }
        }
    }

    private func cancelDictation() {
        guard state == .listening else { return }
        state = .idle
        setStatusIcon(listening: false)
        overlay.hide()
        let start = startTask
        Task {
            _ = try? await start?.value
            transcriber.cancel()
        }
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
            onHotkeyChange: { [weak self] key in
                guard let self else { return }
                self.hotkey = key
                self.hotkeys.hotkey = key
                self.hotkeys.start()
            },
            onDone: { [weak self] in self?.defaults.set(true, forKey: "setupComplete") }
        )
    }

    @objc private func editStyle() {
        StyleGuide.ensureExists()
        NSWorkspace.shared.open(AppPaths.styleFile)
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
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func showLog() { NSWorkspace.shared.open(AppPaths.logFile) }
    @objc private func quit() { NSApp.terminate(nil) }
}
