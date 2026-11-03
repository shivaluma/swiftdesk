import DiagnosticsCore
import Foundation
import Observation
import ServiceManagement

// "Open at Login" (0.1.9): SwiftDesk registers itself as a login item with `SMAppService.mainApp` (macOS 13+), so an
// unattended Host comes back after a restart once the user is logged in. No launch agent or daemon is installed; the
// optional external watchdog LaunchAgent (`scripts/swiftdesk-watchdog.sh`, `com.swiftdesk.watchdog`) is not touched
// and may run alongside (LaunchServices opens one instance either way).
//
// The system (Background Task Management) owns the truth: the switch always shows `SMAppService.Status` read back
// after every change, at launch and whenever SwiftDesk becomes active, because the user can turn the item off in
// System Settings › General › Login Items at any time.

/// `SMAppService.Status` as SwiftDesk shows it.
public enum LoginItemStatus: Sendable, Equatable {
    /// Not a login item.
    case notRegistered
    /// Opens at login.
    case enabled
    /// Registered, but switched off in System Settings › General › Login Items (or not yet approved there).
    case requiresApproval
    /// The framework has no record of the app: what an app that never registered reports (seen on macOS 27 for an
    /// ad-hoc signed bundle), and an executable outside an app bundle (`swift run`). The switch is off but usable.
    case notFound
}

/// Why registering or unregistering failed, from the `NSError` ServiceManagement threw.
public enum LoginItemFailure: Sendable, Equatable {
    /// `kSMErrorAlreadyRegistered`: nothing to do (treated as success).
    case alreadyRegistered
    /// `kSMErrorJobNotFound` on unregister: already gone (treated as success).
    case notRegistered
    /// `kSMErrorLaunchDeniedByUser`: the user switched the item off in System Settings.
    case deniedByUser
    /// `kSMErrorInvalidSignature`: macOS refused the app's code signature.
    case invalidSignature
    /// Anything else, kept as domain and code for the note (no user data is in either).
    case other(domain: String, code: Int)

    /// Maps an error thrown by `SMAppService.register()` / `unregister()`. Codes are compared only in
    /// `SMAppServiceErrorDomain`, so an unrelated POSIX or Cocoa error with the same number stays `.other`.
    public static func from(_ error: any Error) -> LoginItemFailure {
        let error = error as NSError
        guard error.domain == SMAppServiceErrorDomain else {
            return .other(domain: error.domain, code: error.code)
        }
        switch error.code {
        case kSMErrorAlreadyRegistered: return .alreadyRegistered
        case kSMErrorJobNotFound: return .notRegistered
        case kSMErrorLaunchDeniedByUser: return .deniedByUser
        case kSMErrorInvalidSignature: return .invalidSignature
        default: return .other(domain: error.domain, code: error.code)
        }
    }

    /// The failure leaves the item in the state that was asked for.
    public var isBenign: Bool {
        switch self {
        case .alreadyRegistered, .notRegistered: true
        case .deniedByUser, .invalidSignature, .other: false
        }
    }
}

/// Where the running app lives, which decides whether a login item can work and keep working.
public enum LoginItemLocation: Sendable, Equatable {
    /// `/Applications` or `~/Applications`.
    case applications
    /// A random read-only copy macOS made of a quarantined app (App Translocation): the registration would point at a
    /// path that disappears.
    case translocated
    /// Any other folder (Downloads, a build folder, a disk image): works, but moving the app breaks the item.
    case elsewhere(folder: String)
    /// Not an app bundle at all (`swift run`): `SMAppService.mainApp` has nothing to register.
    case notAppBundle

    public static func classify(bundleURL: URL, homeDirectory: String = NSHomeDirectory()) -> LoginItemLocation {
        let url = bundleURL.standardizedFileURL
        guard url.pathExtension == "app" else { return .notAppBundle }
        let path = url.path
        if path.contains("/AppTranslocation/") { return .translocated }
        let folder = url.deletingLastPathComponent().path
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        if folder == "/Applications" || folder.hasPrefix("/Applications/")
            || folder == home + "/Applications" || folder.hasPrefix(home + "/Applications/") {
            return .applications
        }
        let display = folder == home ? "~" : (folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder)
        return .elsewhere(folder: String(display))
    }
}

/// The login-item API SwiftDesk uses, so tests never touch the real Login Items (production: `SystemLoginItemService`).
@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    /// The running app's bundle, for `LoginItemLocation`.
    var bundleURL: URL { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings › General › Login Items.
    func openSystemSettingsLoginItems()
}

/// `SMAppService.mainApp`: the app itself as a login item (no helper bundle, no launchd plist).
///
/// Signing, from a probe on macOS 27 (an ad-hoc signed bundle, unsandboxed like SwiftDesk): `register()` succeeds
/// without any prompt or approval (macOS only posts a "Login Item Added" notification), also outside /Applications;
/// repeating `register()` or `unregister()` throws nothing; the status stays `.enabled` after the bundle is re-signed
/// ad hoc with a new code hash. Whether launchd still opens such a re-signed ad-hoc build at login was not verified (it
/// needs a log-out). If Background Task Management ever drops the item (status back to not registered while the user
/// wanted it), SwiftDesk says so and turning the switch on registers the running build again; a stable development
/// certificate is the safer choice for an unattended Host.
@MainActor
public final class SystemLoginItemService: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public var bundleURL: URL { Bundle.main.bundleURL }

    public func register() throws { try SMAppService.mainApp.register() }

    public func unregister() throws { try SMAppService.mainApp.unregister() }

    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// What Host › Startup shows for "Open at Login": switch position, caption and at most one note. Pure, unit-tested.
public struct LoginItemPresentation: Sendable, Equatable {
    public enum NoteTone: Sendable, Equatable {
        /// Information (secondary).
        case info
        /// Something to fix (orange).
        case warning
    }

    /// The switch is on while SwiftDesk is registered, approved or not.
    public var isOn: Bool
    /// False only when there is nothing to register (not an app bundle).
    public var isAvailable: Bool
    public var caption: String
    /// Show "Approve in System Settings" with a button to Login Items.
    public var needsApproval: Bool
    public var note: String?
    public var noteTone: NoteTone

    public static let approvalMessage = "Approve in System Settings › General › Login Items: turn SwiftDesk on there."

    /// - Parameters:
    ///   - status: read back from the system.
    ///   - wanted: what the user last chose in SwiftDesk (persisted), to explain an item removed outside SwiftDesk.
    ///   - failure: the last register/unregister error, if it was not benign.
    ///   - location: where the running app lives.
    ///   - listensAtLaunch: "Start listening when SwiftDesk opens", so the caption can say whether Viewers can connect.
    public static func make(status: LoginItemStatus, wanted: Bool, failure: LoginItemFailure?,
                            location: LoginItemLocation, listensAtLaunch: Bool) -> LoginItemPresentation {
        var result = LoginItemPresentation(isOn: false, isAvailable: true, caption: "", needsApproval: false,
                                           note: nil, noteTone: .info)
        switch status {
        case .enabled:
            result.isOn = true
            result.caption = listensAtLaunch
                ? "SwiftDesk opens when you log in to this Mac and starts listening."
                : "SwiftDesk opens when you log in to this Mac. Turn on \u{201C}Start listening when SwiftDesk opens\u{201D} so Viewers can connect without a click here."
        case .requiresApproval:
            result.isOn = true
            result.needsApproval = true
            result.caption = "Added, but macOS won\u{2019}t open SwiftDesk at login until you allow it."
        case .notRegistered, .notFound:
            result.caption = "Off. SwiftDesk opens only when you open it."
        }

        if location == .notAppBundle && status != .enabled && status != .requiresApproval {
            result.isAvailable = false
            result.note = "Only available when SwiftDesk runs as an app (SwiftDesk.app), not as a bare executable."
            return result
        }
        if let failure, !failure.isBenign {
            result.note = message(for: failure)
            result.noteTone = .warning
            return result
        }
        if wanted && !result.isOn {
            result.note = "SwiftDesk is no longer in Login Items: it was removed in System Settings, or this copy of the app changed (a new build or a moved app). Turn the switch on to add it again."
            result.noteTone = .warning
            return result
        }
        switch location {
        case .translocated:
            result.note = "macOS is running SwiftDesk from a temporary copy. Move SwiftDesk to the Applications folder and open it from there, then turn this on."
            result.noteTone = .warning
        case .elsewhere(let folder):
            result.note = "SwiftDesk is running from \(folder). Login Items open the app where it was added, so move it to Applications first if you plan to."
            result.noteTone = .info
        case .applications, .notAppBundle:
            break
        }
        return result
    }

    static func message(for failure: LoginItemFailure) -> String {
        switch failure {
        case .alreadyRegistered, .notRegistered:
            ""
        case .deniedByUser:
            "SwiftDesk is switched off in System Settings › General › Login Items. Turn it on there."
        case .invalidSignature:
            "macOS rejected SwiftDesk\u{2019}s code signature, so it can\u{2019}t be a login item. Install a signed build (scripts/build-app.sh, or Xcode with \u{201C}Sign to Run Locally\u{201D}) in Applications and try again."
        case .other(let domain, let code):
            "Couldn\u{2019}t change Login Items (\(domain) error \(code)). Try again, or add SwiftDesk in System Settings › General › Login Items."
        }
    }
}

/// Host › Startup › "Open at Login": the switch's state, kept in sync with Login Items.
///
/// Main actor, refreshed at launch (init), after every change and whenever the app becomes active
/// (`SwiftDeskAppDelegate.applicationDidBecomeActive`). The status read is a quick call to Background Task
/// Management, never made per frame.
@MainActor
@Observable
public final class LoginItemController {
    /// UserDefaults key of the user's last choice in SwiftDesk (not the truth, which is the system's status).
    public static let wantedKey = "SwiftDesk.host.openAtLogin"

    public private(set) var status: LoginItemStatus
    /// The user's last choice in SwiftDesk (persisted).
    public private(set) var wanted: Bool
    /// The last register/unregister error that left the item in the wrong state; cleared by the next success, or when
    /// the status changes outside SwiftDesk (the user fixed it in System Settings, or removed the item there).
    public private(set) var failure: LoginItemFailure?
    public let location: LoginItemLocation

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let defaults: UserDefaults

    public init(service: any LoginItemService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.status = service.status
        self.wanted = defaults.bool(forKey: Self.wantedKey)
        self.location = LoginItemLocation.classify(bundleURL: service.bundleURL)
    }

    /// The switch position.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }

    public func presentation(listensAtLaunch: Bool) -> LoginItemPresentation {
        LoginItemPresentation.make(status: status, wanted: wanted, failure: failure, location: location,
                                   listensAtLaunch: listensAtLaunch)
    }

    /// Re-reads the status (the user may have changed it in System Settings). A changed status makes the last error
    /// stale: it described the item before that change, and the "no longer in Login Items" note still covers an item
    /// that is off although the user wants it.
    public func refresh() {
        let current = service.status
        guard current != status else { return }
        status = current
        failure = nil
    }

    /// The switch: registers or unregisters, then shows what the system reports.
    public func setEnabled(_ enabled: Bool) {
        wanted = enabled
        defaults.set(enabled, forKey: Self.wantedKey)
        do {
            if enabled { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            let mapped = LoginItemFailure.from(error)
            failure = mapped.isBenign ? nil : mapped
        }
        status = service.status
        if let failure {
            Log.session.error("Open at Login: \(enabled ? "register" : "unregister", privacy: .public) failed (\(String(describing: failure), privacy: .public))")
        } else {
            Log.session.notice("Open at Login: \(enabled ? "registered" : "unregistered", privacy: .public), status \(String(describing: self.status), privacy: .public)")
        }
    }

    /// The approval note's button.
    public func openSystemSettings() {
        service.openSystemSettingsLoginItems()
    }
}
