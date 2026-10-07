import AppKit
import Carbon.HIToolbox

/// Which modifier key acts as push-to-talk. Modifiers are used because holding them alone types nothing.
enum Hotkey: String, CaseIterable {
    case leftOption, rightOption, rightCommand, function

    var title: String {
        switch self {
        case .leftOption: "Left Option (⌥)"
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .function: "fn / Globe"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftOption: UInt16(kVK_Option)
        case .rightOption: UInt16(kVK_RightOption)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .function: UInt16(kVK_Function)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftOption, .rightOption: .option
        case .rightCommand: .command
        case .function: .function
        }
    }

    /// Whether this specific key is down. The generic flags (.option etc.) are shared by the left and
    /// right keys, so use the device-dependent bits from IOLLEvent.h to tell them apart.
    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        // No device-specific bits at all: fall back to the generic flag rather than say "not held".
        if raw & 0x207F == 0, self != .function { return flags.contains(flag) }
        switch self {
        case .leftOption: return raw & 0x20 != 0     // NX_DEVICELALTKEYMASK
        case .rightOption: return raw & 0x40 != 0    // NX_DEVICERALTKEYMASK
        case .rightCommand: return raw & 0x10 != 0   // NX_DEVICERCMDKEYMASK
        case .function: return flags.contains(.function)
        }
    }
}

/// Watches the push-to-talk key globally. Needs Accessibility permission.
///
/// Pressing any other key while holding it cancels the dictation, so normal shortcuts like
/// ⌥3 for # on a UK keyboard keep working.
@MainActor
final class HotkeyMonitor {
    var hotkey: Hotkey = .leftOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false {
        didSet { isDown ? startWatchdog() : stopWatchdog() }
    }
    private var watchdog: Timer?

    func start() {
        stop()
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        // Also catch events while our own overlay/menu is key.
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
            return event
        }
        monitors = [flags, keys, localFlags].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
    }

    /// Whether the key is physically held right now, read from the system rather than from events.
    var isHeldNow: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return hotkey.isPressed(in: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }

    /// Key-up events can go missing (e.g. a system permission dialog takes focus mid-press, or
    /// Accessibility isn't granted yet), so while held we also poll the real key state.
    ///
    /// Fail-safe: polling only ends a press after it has itself seen the key held during it, so if the
    /// key state ever reads as blank we fall back to events (and the max-duration stop) instead of
    /// cutting every dictation short.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        var sawHeld = false
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDown else { return }
                if self.isHeldNow { sawHeld = true; return }
                guard sawHeld else { return }
                Log.info("Hotkey release detected by polling (key-up event was missed)")
                self.isDown = false
                self.onRelease?()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Ends a press from outside (e.g. the max-duration safety stop).
    func forceRelease() {
        guard isDown else { return }
        isDown = false
        onRelease?()
    }

    private func handleFlags(_ event: NSEvent) {
        if event.keyCode == hotkey.keyCode {
            let pressed = hotkey.isPressed(in: event.modifierFlags)
            if pressed, !isDown {
                isDown = true
                onPress?()
            } else if !pressed, isDown {
                isDown = false
                onRelease?()
            }
        } else if isDown {
            // Another modifier joined in: it's a shortcut, not dictation.
            let all: NSEvent.ModifierFlags = [.command, .control, .shift, .option, .function]
            let others = all.subtracting(hotkey.flag)
            if !event.modifierFlags.intersection(others).isEmpty {
                isDown = false
                onCancel?()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isDown else { return }
        isDown = false
        onCancel?()
    }
}
