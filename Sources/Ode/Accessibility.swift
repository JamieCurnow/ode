import AppKit
import ApplicationServices

enum Accessibility {
    /// Opens Settings › Accessibility with a fresh, unticked Ode row to switch on.
    ///
    /// macOS ties the grant to the exact signed build. After an update (release builds are ad-hoc
    /// signed) the old row stays ticked but no longer matches, so AXIsProcessTrusted() is false while
    /// Settings shows Ode as allowed. Clearing our own entry first replaces that stale row.
    static func requestAccess() {
        if !AXIsProcessTrusted(), let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            do {
                try reset.run()
                reset.waitUntilExit()
            } catch {
                Log.error("Couldn't reset Accessibility entry: \(error)")
            }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
