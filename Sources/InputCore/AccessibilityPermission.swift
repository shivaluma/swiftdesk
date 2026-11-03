import AppKit
// `kAXTrustedCheckOptionPrompt` is imported as a mutable C global; @preconcurrency lets Swift 6 read it.
@preconcurrency import ApplicationServices

/// Accessibility (TCC "Accessibility") trust, which macOS requires before `CGEventPost` can drive the Host.
///
/// Without it, posted events are silently discarded, so the Host must check before authorizing a session and
/// tell the user instead of appearing to "connect but not respond".
public enum AccessibilityPermission {
    /// Whether this process may post input events. With `prompt: true` macOS shows its one-time system alert
    /// pointing the user at System Settings (it does not block and does not grant anything by itself).
    public static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Settings deep link for Privacy & Security > Accessibility.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Opens Privacy & Security > Accessibility so the user can enable the app.
    public static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
