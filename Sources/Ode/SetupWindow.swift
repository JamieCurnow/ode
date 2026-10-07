import AppKit
import AVFoundation
import SwiftUI

/// What the setup screen knows about the user's Claude Code install.
enum ClaudeStatus: Equatable {
    case checking
    case notInstalled
    case loggedOut
    case ready(email: String?, plan: String?)

    static func check() async -> ClaudeStatus {
        guard let claude = ClaudeProcess.locateCLI() else { return .notInstalled }
        return await withCheckedContinuation { cont in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = claude
            process.arguments = ["auth", "status", "--json"]
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["loggedIn"] as? Bool == true
                else { cont.resume(returning: .loggedOut); return }
                cont.resume(returning: .ready(
                    email: json["email"] as? String,
                    plan: json["subscriptionType"] as? String
                ))
            }
            do { try process.run() } catch { cont.resume(returning: .notInstalled) }
        }
    }
}

@MainActor
@Observable
final class SetupModel {
    var claude: ClaudeStatus = .checking
    var micGranted = false
    var accessibilityGranted = false
    /// The style guide no longer matches the default, i.e. Personalise (or the user) has written it.
    var personalised = false
    var hotkey: Hotkey
    var tryText = ""

    @ObservationIgnored var onHotkeyChange: ((Hotkey) -> Void)?
    @ObservationIgnored var onDone: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    func start() {
        refreshPermissions()
        recheckClaude()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        let style = (try? String(contentsOf: AppPaths.styleFile, encoding: .utf8)) ?? ""
        personalised = !style.isEmpty
            && style.trimmingCharacters(in: .whitespacesAndNewlines)
            != StyleGuide.defaultStyle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recheckClaude() {
        claude = .checking
        Task { claude = await ClaudeStatus.check() }
    }

    func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var claudeReady: Bool {
        if case .ready = claude { return true }
        return false
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private var model: SetupModel?

    func show(hotkey: Hotkey, onHotkeyChange: @escaping (Hotkey) -> Void, onDone: @escaping () -> Void) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SetupModel(hotkey: hotkey)
        model.onHotkeyChange = onHotkeyChange
        model.onDone = { [weak self] in
            onDone()
            self?.close()
        }
        model.start()
        self.model = model

        let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
        window.title = "Ode Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.stop()
                self?.model = nil
                self?.window = nil
            }
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct SetupView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Ode")
                    .font(.system(size: 22, weight: .semibold))
                Text("Hold a key, talk, let go. Your words get cleaned up by Claude in your own style and pasted wherever you're typing.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                claudeRow
                Divider()
                StepRow(
                    number: 2, title: "Microphone",
                    detail: "To hear you while you hold the key.",
                    done: model.micGranted
                ) {
                    Button("Allow") { model.requestMic() }
                }
                Divider()
                StepRow(
                    number: 3, title: "Accessibility",
                    detail: "To notice the push-to-talk key and paste the text. Turn on Ode in the list.",
                    done: model.accessibilityGranted
                ) {
                    Button("Open Settings") { model.openAccessibility() }
                }
                Divider()
                StepRow(number: 4, title: "Push-to-talk key", detail: "Hold it to talk, let go to paste.", done: true) {
                    Picker("", selection: $model.hotkey) {
                        ForEach(Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: model.hotkey) { _, key in model.onHotkeyChange?(key) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    StepHeader(number: 5, title: "Try it", done: !model.tryText.isEmpty)
                    TextField("Click here, hold \(model.hotkey.title) and say something…", text: $model.tryText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .disabled(!model.micGranted || !model.accessibilityGranted)
                }
                .padding(.vertical, 12)
                Divider()
                StepRow(
                    number: 6, title: "Make it sound like you",
                    detail: "Opens Claude Code in Terminal. It uses your connected tools (like Slack or Gmail) to read some of your own recent messages, then writes your personal style guide and a list of names it should know. You approve each tool it uses.",
                    done: model.personalised
                ) {
                    Button(model.personalised ? "Personalise Again" : "Personalise") { AgentSession.launch(.personalise) }
                        .disabled(!model.claudeReady)
                }
            }
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text("You can come back here any time from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.onDone?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder private var claudeRow: some View {
        switch model.claude {
        case .checking:
            StepRow(number: 1, title: "Claude Code", detail: "Checking…", done: false) { ProgressView().controlSize(.small) }
        case .notInstalled:
            StepRow(
                number: 1, title: "Claude Code",
                detail: "Needed for the cleanup. Install it by running this in Terminal, then click Re-check:\ncurl -fsSL https://claude.ai/install.sh | bash",
                done: false
            ) {
                VStack(alignment: .trailing) {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("curl -fsSL https://claude.ai/install.sh | bash", forType: .string)
                    }
                    Button("Re-check") { model.recheckClaude() }
                }
            }
        case .loggedOut:
            StepRow(number: 1, title: "Claude Code", detail: "Installed, but not signed in to your Claude account.", done: false) {
                VStack(alignment: .trailing) {
                    Button("Sign In") { AgentSession.launchLogin() }
                    Button("Re-check") { model.recheckClaude() }
                }
            }
        case let .ready(email, plan):
            let who = [email, plan.map { "\($0.capitalized) plan" }].compactMap { $0 }.joined(separator: " · ")
            StepRow(
                number: 1, title: "Claude Code",
                detail: "Signed in\(who.isEmpty ? "" : " as \(who)"). Cleanup runs on your Claude subscription.",
                done: true
            ) { EmptyView() }
        }
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 22, height: 22)
            Text(title).font(.headline)
        }
    }
}

private struct StepRow<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                StepHeader(number: number, title: title, done: done)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 12)
    }
}
