import AppUI
import SwiftUI

/// SwiftDesk entry point. All UI and session logic lives in the `AppUI` library so the SwiftPM executable and the
/// Xcode app target (project.yml) build the exact same app from this one file.
@main
struct SwiftDeskApp: App {
    @NSApplicationDelegateAdaptor(SwiftDeskAppDelegate.self) private var delegate

    var body: some Scene {
        SwiftDeskScenes(model: delegate.model)
    }
}
