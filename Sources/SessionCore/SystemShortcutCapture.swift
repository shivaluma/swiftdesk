import Foundation
import InputCore

/// Where the Viewer's "Send system shortcuts to the remote Mac" switch stands, for the settings row and the toolbar.
public enum SystemShortcutCaptureStatus: Sendable, Equatable {
    /// The switch is off: system shortcuts act on this Mac (the Send Keys menu still works).
    case off
    /// The switch is on, but SwiftDesk lacks Accessibility permission, which the keyboard tap needs.
    case needsPermission
    /// On and allowed; the tap is installed only while controlling a streaming session in the focused stream window.
    case standby
    /// The tap is installed: ⌘Tab, ⌘Space, Mission Control … go to the Host.
    case active
    /// macOS refused the tap although Accessibility looked granted (e.g. the grant belongs to an older build).
    case unavailable

    /// Pure arming rule: the tap exists only inside an authorized, streaming session, while the user is controlling
    /// it and the stream view has keyboard focus (key window of the active app). Every other state removes it.
    public static func shouldArm(enabled: Bool, permitted: Bool, streaming: Bool, capturing: Bool,
                                 focused: Bool) -> Bool {
        enabled && permitted && streaming && capturing && focused
    }

    public static func make(enabled: Bool, permitted: Bool, armed: Bool, installed: Bool) -> SystemShortcutCaptureStatus {
        guard enabled else { return .off }
        guard permitted else { return .needsPermission }
        guard armed else { return .standby }
        return installed ? .active : .unavailable
    }
}

/// Makes the production keyboard tap (`SystemShortcutTap`); tests pass a fake.
public typealias SystemShortcutTapFactory = @MainActor (
    _ isArmed: @escaping @MainActor () -> Bool,
    _ deliver: @escaping @MainActor (TapKeyEvent) -> Void
) -> any SystemShortcutTapping
