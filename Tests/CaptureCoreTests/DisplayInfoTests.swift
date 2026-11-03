import AppKit
import CoreGraphics
import Testing
@testable import CaptureCore

/// Enumeration through CoreGraphics + NSScreen only: never touches ScreenCaptureKit, so no permission prompt.
@Suite("DisplayInfo (CoreGraphics enumeration)")
struct DisplayInfoTests {
    @Test("Active display IDs are unique, main display first")
    func activeIDs() {
        let ids = DisplayInfo.activeDisplayIDs()
        #expect(Set(ids).count == ids.count)
        if let first = ids.first {
            #expect(first == CGMainDisplayID())
        }
    }

    @Test("Each display's info matches CoreGraphics")
    @MainActor
    func consistentWithCoreGraphics() throws {
        let displays = DisplayInfo.activeDisplays()
        let ids = DisplayInfo.activeDisplayIDs()
        #expect(displays.map(\.id) == ids)
        for info in displays {
            #expect(!info.name.isEmpty)
            #expect(info.frame == CGDisplayBounds(info.id))
            let mode = try #require(CGDisplayCopyDisplayMode(info.id))
            #expect(info.pixelWidth == mode.pixelWidth)
            #expect(info.pixelHeight == mode.pixelHeight)
            #expect(info.pixelWidth > 0 && info.pixelHeight > 0)
            #expect(info.backingScale >= 1)
            // Pixels and points have the same aspect (modes scale uniformly).
            let pixelAspect = Double(info.pixelWidth) / Double(info.pixelHeight)
            let pointAspect = Double(info.frame.width) / Double(info.frame.height)
            #expect(abs(pixelAspect - pointAspect) / pointAspect < 0.01)
        }
    }

    @Test("Names come from NSScreen.localizedName matched by NSScreenNumber")
    @MainActor
    func namesMatchNSScreen() {
        let names = DisplayInfo.screenNames()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            #expect(names[number.uint32Value] == screen.localizedName)
        }
        for info in DisplayInfo.activeDisplays() {
            if let name = names[info.id] {
                #expect(info.name == name)
            }
        }
    }

    @Test("Main display frame origin is (0,0) in global CG coordinates")
    @MainActor
    func mainDisplayOrigin() {
        guard let main = DisplayInfo.activeDisplays().first else { return }   // headless CI: nothing to check
        #expect(main.frame.origin == .zero)
    }

    @Test("Unknown display yields nil; fallback names are non-empty")
    func unknownDisplay() {
        #expect(DisplayInfo.make(id: 0xDEAD_BEEF, name: nil) == nil)
        #expect(!DisplayInfo.fallbackName(for: 0xDEAD_BEEF).isEmpty)
        #expect(DisplayInfo.currentPixelSize(of: 0xDEAD_BEEF) == nil)
    }

    @Test("Hashable/Equatable cover every field")
    func hashable() {
        let a = DisplayInfo(id: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixelWidth: 3456, pixelHeight: 2234)
        var b = a
        #expect(a == b && a.hashValue == b.hashValue)
        b.frame.origin.x = 1
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        #expect(a.backingScale == 2)
        #expect(a.pointSize == CGSize(width: 1728, height: 1117))
    }
}

@Suite("ScreenCapturePermission")
struct ScreenCapturePermissionTests {
    @Test("Preflight is side-effect free and agrees with CoreGraphics")
    func preflight() {
        #expect(ScreenCapturePermission.isGranted() == CGPreflightScreenCaptureAccess())
    }

    @Test("Settings URL targets the Screen Recording privacy pane")
    func settingsURL() {
        let url = ScreenCapturePermission.settingsURL
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.absoluteString.hasSuffix("?Privacy_ScreenCapture"))
    }
}
