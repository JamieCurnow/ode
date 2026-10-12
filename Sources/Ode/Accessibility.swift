import AppKit
import ApplicationServices

enum Accessibility {
    /// Set before relaunching so the next launch asks for Accessibility even during first-run setup.
    private static let askOnLaunchKey = "askAccessibilityOnLaunch"

    /// Gets a fresh, unticked Ode row into Settings › Accessibility to switch on.
    ///
    /// macOS ties the grant to the exact signed build. After an update (release builds are ad-hoc
    /// signed) the old row stays ticked but no longer matches, so AXIsProcessTrusted() is false while
    /// Settings shows Ode as allowed. We clear our own entry, but macOS only shows its request once
    /// per process, so we then relaunch and ask again from the new process.
    static func requestAccess() {
        guard !AXIsProcessTrusted(), let bundleID = Bundle.main.bundleIdentifier else {
            openSettings()
            return
        }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleID]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch {
            Log.error("Couldn't reset Accessibility entry: \(error)")
            ask()
            openSettings()
            return
        }
        Log.info("Cleared stale Accessibility entry, relaunching to ask again")
        UserDefaults.standard.set(true, forKey: askOnLaunchKey)
        relaunch()
    }

    /// Call at launch: true once after requestAccess() relaunched us.
    static func consumeAskOnLaunch() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: askOnLaunchKey) }
        return UserDefaults.standard.bool(forKey: askOnLaunchKey)
    }

    /// Shows macOS's request, which also adds Ode to the Accessibility list.
    static func ask() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        do {
            try reopen.run()
            NSApp.terminate(nil)
        } catch {
            Log.error("Couldn't relaunch: \(error)")
            ask()
            openSettings()
        }
    }
}
