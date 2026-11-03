import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import AppUI

/// Login Items stand-in (0.1.9): scripted status and errors; tests never register the real app.
@MainActor
final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus
    var bundleURL: URL
    /// Status after a successful `register()` (`.requiresApproval` when the user switched the item off before).
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var settingsOpened = 0

    init(status: LoginItemStatus = .notRegistered,
         bundleURL: URL = URL(fileURLWithPath: "/Applications/SwiftDesk.app")) {
        self.status = status
        self.bundleURL = bundleURL
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() { settingsOpened += 1 }
}

private func smError(_ code: Int) -> NSError { NSError(domain: SMAppServiceErrorDomain, code: code) }

@MainActor
@Suite("Open at Login")
struct LoginItemTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SwiftDesk.LoginItemTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: Pure mapping

    @Test func serviceManagementErrorsAreMapped() {
        #expect(LoginItemFailure.from(smError(kSMErrorAlreadyRegistered)) == .alreadyRegistered)
        #expect(LoginItemFailure.from(smError(kSMErrorJobNotFound)) == .notRegistered)
        #expect(LoginItemFailure.from(smError(kSMErrorLaunchDeniedByUser)) == .deniedByUser)
        #expect(LoginItemFailure.from(smError(kSMErrorInvalidSignature)) == .invalidSignature)
        #expect(LoginItemFailure.from(smError(1)) == .other(domain: SMAppServiceErrorDomain, code: 1))
        // The same number in another domain is not a ServiceManagement code.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: kSMErrorAlreadyRegistered)
        #expect(LoginItemFailure.from(posix) == .other(domain: NSPOSIXErrorDomain, code: kSMErrorAlreadyRegistered))
        #expect(LoginItemFailure.alreadyRegistered.isBenign && LoginItemFailure.notRegistered.isBenign)
        #expect(!LoginItemFailure.deniedByUser.isBenign && !LoginItemFailure.invalidSignature.isBenign)
    }

    @Test func appLocationIsClassified() {
        let home = "/Users/tester"
        func classify(_ path: String) -> LoginItemLocation {
            LoginItemLocation.classify(bundleURL: URL(fileURLWithPath: path), homeDirectory: home)
        }
        #expect(classify("/Applications/SwiftDesk.app") == .applications)
        #expect(classify("/Applications/Utilities/SwiftDesk.app") == .applications)
        #expect(classify("/Users/tester/Applications/SwiftDesk.app") == .applications)
        #expect(classify("/private/var/folders/x/T/AppTranslocation/1234/d/SwiftDesk.app") == .translocated)
        #expect(classify("/Users/tester/Downloads/SwiftDesk.app") == .elsewhere(folder: "~/Downloads"))
        #expect(classify("/Volumes/SwiftDesk/SwiftDesk.app") == .elsewhere(folder: "/Volumes/SwiftDesk"))
        #expect(classify("/Applications Old/SwiftDesk.app") == .elsewhere(folder: "/Applications Old"))
        #expect(classify("/Users/tester/code/.build/debug") == .notAppBundle)
    }

    @Test func presentationFollowsTheSystemStatus() {
        func make(_ status: LoginItemStatus, wanted: Bool = false, failure: LoginItemFailure? = nil,
                  location: LoginItemLocation = .applications, listens: Bool = true) -> LoginItemPresentation {
            LoginItemPresentation.make(status: status, wanted: wanted, failure: failure, location: location,
                                       listensAtLaunch: listens)
        }

        let enabled = make(.enabled, wanted: true)
        #expect(enabled.isOn && enabled.isAvailable && !enabled.needsApproval && enabled.note == nil)
        #expect(enabled.caption.contains("starts listening"))
        #expect(make(.enabled, listens: false).caption.contains("Start listening when SwiftDesk opens"))

        let approval = make(.requiresApproval, wanted: true)
        #expect(approval.isOn && approval.needsApproval && approval.note == nil)
        #expect(LoginItemPresentation.approvalMessage.contains("System Settings › General › Login Items"))

        for status in [LoginItemStatus.notRegistered, .notFound] {
            let off = make(status)
            #expect(!off.isOn && off.isAvailable && !off.needsApproval && off.note == nil, "\(status)")
            // Wanted but gone: removed in System Settings, or a new build.
            let removed = make(status, wanted: true)
            #expect(!removed.isOn && removed.noteTone == .warning)
            #expect(removed.note?.contains("no longer in Login Items") == true)
        }
    }

    @Test func presentationExplainsFailuresAndLocations() {
        func make(_ status: LoginItemStatus = .notRegistered, wanted: Bool = true, failure: LoginItemFailure? = nil,
                  location: LoginItemLocation = .applications) -> LoginItemPresentation {
            LoginItemPresentation.make(status: status, wanted: wanted, failure: failure, location: location,
                                       listensAtLaunch: false)
        }
        let signature = make(failure: .invalidSignature)
        #expect(signature.noteTone == .warning && signature.note?.contains("code signature") == true)
        #expect(make(failure: .deniedByUser).note?.contains("Login Items") == true)
        #expect(make(failure: .other(domain: "SMAppServiceErrorDomain", code: 1)).note?.contains("error 1") == true)
        // A failure outranks the "removed" note; benign failures show nothing.
        #expect(make(failure: .alreadyRegistered).note?.contains("no longer") == true)
        #expect(make(.enabled, failure: .alreadyRegistered).note == nil)

        let bare = make(.notFound, wanted: false, location: .notAppBundle)
        #expect(!bare.isAvailable && !bare.isOn && bare.note?.contains("SwiftDesk.app") == true)
        // Registered earlier from a bundle: still switchable off.
        #expect(make(.enabled, location: .notAppBundle).isAvailable)

        let translocated = make(wanted: false, location: .translocated)
        #expect(translocated.isAvailable && translocated.noteTone == .warning)
        #expect(translocated.note?.contains("Applications") == true)
        let downloads = make(.enabled, location: .elsewhere(folder: "~/Downloads"))
        #expect(downloads.noteTone == .info && downloads.note?.contains("~/Downloads") == true)
    }

    // MARK: Controller

    @Test func switchRegistersAndShowsTheRealStatus() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, defaults: defaults)
        #expect(!controller.isOn && !controller.wanted && controller.location == .applications)

        controller.setEnabled(true)
        #expect(service.registerCalls == 1 && controller.status == .enabled && controller.isOn)
        #expect(controller.failure == nil)
        #expect(defaults.bool(forKey: LoginItemController.wantedKey))
        #expect(LoginItemController.wantedKey == "SwiftDesk.host.openAtLogin")

        controller.setEnabled(false)
        #expect(service.unregisterCalls == 1 && controller.status == .notRegistered && !controller.isOn)
        #expect(!defaults.bool(forKey: LoginItemController.wantedKey))
        #expect(controller.presentation(listensAtLaunch: true).note == nil)
    }

    @Test func approvalIsRequestedWhenLoginItemsHasItOff() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItemService()
        service.statusAfterRegister = .requiresApproval
        let controller = LoginItemController(service: service, defaults: defaults)
        controller.setEnabled(true)
        let presentation = controller.presentation(listensAtLaunch: true)
        #expect(controller.isOn && presentation.needsApproval)
        controller.openSystemSettings()
        #expect(service.settingsOpened == 1)

        // Approved in System Settings, then SwiftDesk becomes active again.
        service.status = .enabled
        controller.refresh()
        #expect(controller.status == .enabled && !controller.presentation(listensAtLaunch: true).needsApproval)
    }

    @Test func failuresAreShownAndBenignErrorsIgnored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, defaults: defaults)

        service.registerError = smError(kSMErrorInvalidSignature)
        controller.setEnabled(true)
        #expect(controller.failure == .invalidSignature && !controller.isOn)
        #expect(controller.presentation(listensAtLaunch: true).note?.contains("code signature") == true)

        // Already registered elsewhere: success; the next success clears the failure.
        service.registerError = smError(kSMErrorAlreadyRegistered)
        service.status = .enabled
        controller.setEnabled(true)
        #expect(controller.failure == nil && controller.isOn)

        service.unregisterError = smError(kSMErrorJobNotFound)
        service.status = .notRegistered
        controller.setEnabled(false)
        #expect(controller.failure == nil && !controller.isOn && service.unregisterCalls == 1)
    }

    /// Review 0.2.0: a failure fixed in System Settings must not leave its warning next to a switch that is on.
    @Test func failureFixedInSystemSettingsClearsTheNote() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = LoginItemController(service: service, defaults: defaults)
        service.registerError = smError(kSMErrorLaunchDeniedByUser)
        controller.setEnabled(true)
        #expect(controller.failure == .deniedByUser)
        #expect(controller.presentation(listensAtLaunch: true).noteTone == .warning)

        controller.refresh()   // nothing changed yet: the note stays
        #expect(controller.failure == .deniedByUser)

        service.status = .enabled   // turned on in Login Items, then SwiftDesk becomes active again
        controller.refresh()
        #expect(controller.failure == nil)
        let presentation = controller.presentation(listensAtLaunch: true)
        #expect(controller.isOn && presentation.note == nil)

        // Removed outside SwiftDesk after a failed unregister: the old error gives way to the removal note.
        service.unregisterError = smError(1)
        controller.setEnabled(false)
        #expect(controller.failure == .other(domain: SMAppServiceErrorDomain, code: 1))
        service.status = .notRegistered
        controller.refresh()
        #expect(controller.failure == nil && controller.presentation(listensAtLaunch: true).note == nil)
    }

    @Test func removalOutsideSwiftDeskIsExplainedAfterRelaunch() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItemService()
        LoginItemController(service: service, defaults: defaults).setEnabled(true)

        // Removed in System Settings (or a new build that Login Items no longer knows), then SwiftDesk relaunched.
        service.status = .notFound
        let relaunched = LoginItemController(service: service, defaults: defaults)
        #expect(relaunched.wanted && !relaunched.isOn)
        #expect(relaunched.presentation(listensAtLaunch: true).note?.contains("no longer in Login Items") == true)
        #expect(service.registerCalls == 1, "never re-registered behind the user's back")

        // Turned off in Login Items while SwiftDesk runs: picked up on the next activation.
        relaunched.setEnabled(true)
        service.status = .requiresApproval
        relaunched.refresh()
        #expect(relaunched.isOn && relaunched.presentation(listensAtLaunch: true).needsApproval)
    }

    @Test func appModelUsesTheInjectedService() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let service = FakeLoginItemService(status: .enabled)
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults,
                             loginItemService: service)
        #expect(model.loginItem.isOn)
        service.status = .requiresApproval
        // What `SwiftDeskAppDelegate.applicationDidBecomeActive` does.
        model.loginItem.refresh()
        #expect(model.loginItem.status == .requiresApproval)
        model.loginItem.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        #expect(env.defaults.object(forKey: LoginItemController.wantedKey) as? Bool == false)
    }
}
