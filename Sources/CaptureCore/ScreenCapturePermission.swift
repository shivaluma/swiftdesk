import AppKit
import CoreGraphics

/// Screen Recording ("Screen & System Audio Recording") TCC permission.
///
/// SwiftDesk follows Apple's permission model: it checks without prompting, asks macOS to prompt only on an explicit
/// user action, and otherwise sends the user to System Settings. It never tries to work around TCC.
public enum ScreenCapturePermission {
    /// Deep link to the Screen Recording privacy pane. System Settings (macOS 13+) still honours this legacy
    /// `Privacy_ScreenCapture` anchor.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Current authorization, without prompting (`CGPreflightScreenCaptureAccess`).
    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks macOS to show the Screen Recording prompt (`CGRequestScreenCaptureAccess`). Returns the current
    /// authorization; a process that was previously denied is not re-prompted, and a fresh grant usually only
    /// takes effect after the app relaunches, so callers should offer `openSettings()` when this returns false.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings at the Screen Recording pane.
    public static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
