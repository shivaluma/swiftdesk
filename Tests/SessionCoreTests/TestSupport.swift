import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import InputCore
import RenderCore
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Polls until `condition` holds or `timeout` passes. Yields the main actor between polls, so main-queue hops
/// (session state changes, metrics) keep flowing while a `@MainActor` test waits.
@MainActor
func eventually(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Nonisolated variant for tests that are not main-actor bound.
func eventuallyDetached(timeout: TimeInterval = 10, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Uniquely labelled keychain identities, deleted when the test ends.
final class TestIdentities: @unchecked Sendable {
    let host: DeviceIdentity
    let viewer: DeviceIdentity
    private let labels: [String]

    init() throws {
        let suffix = UUID().uuidString
        let hostLabel = "SwiftDesk SessionTest Host \(suffix)"
        let viewerLabel = "SwiftDesk SessionTest Viewer \(suffix)"
        labels = [hostLabel, viewerLabel]
        host = try DeviceIdentity.loadOrCreate(label: hostLabel)
        viewer = try DeviceIdentity.loadOrCreate(label: viewerLabel)
    }

    /// An extra identity (e.g. a second Viewer), cleaned up with the others.
    func extra(_ name: String) throws -> DeviceIdentity {
        let label = "SwiftDesk SessionTest \(name) \(UUID().uuidString)"
        extraLabels.withLock { $0.append(label) }
        return try DeviceIdentity.loadOrCreate(label: label)
    }

    private let extraLabels = Mutex<[String]>([])

    func cleanUp() {
        for label in labels + extraLabels.withLock({ $0 }) { try? DeviceIdentity.delete(label: label) }
    }
}

/// A private `UserDefaults` suite, removed on cleanup.
final class TestDefaults: @unchecked Sendable {
    let suiteName = "SwiftDesk.SessionCoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// `InputSink` that records everything instead of posting CGEvents.
final class RecordingInputSink: InputSink, @unchecked Sendable {
    private struct State {
        var messages: [ControlMessage] = []
        var pointers: [PointerState] = []
        var authorizations: [Bool] = []
        var displayFrames: [CGRect] = []
        var releaseAllCount = 0
        var authorized = false
    }
    private let state = Mutex(State())

    func handle(_ message: ControlMessage) {
        state.withLock { s in
            guard s.authorized else { return }
            s.messages.append(message)
        }
    }

    func handlePointer(_ pointer: PointerState) {
        state.withLock { s in
            guard s.authorized else { return }
            s.pointers.append(pointer)
        }
    }

    func setAuthorized(_ authorized: Bool) {
        state.withLock { s in
            s.authorizations.append(authorized)
            s.authorized = authorized
            if !authorized { s.releaseAllCount += 1 }
        }
    }

    func updateDisplayFrame(_ frame: CGRect) {
        state.withLock { $0.displayFrames.append(frame) }
    }

    func releaseAll() {
        state.withLock { $0.releaseAllCount += 1 }
    }

    var canInject: Bool { state.withLock { $0.authorized } }
    var messages: [ControlMessage] { state.withLock { $0.messages } }
    var pointers: [PointerState] { state.withLock { $0.pointers } }
    var authorizations: [Bool] { state.withLock { $0.authorizations } }
    var displayFrames: [CGRect] { state.withLock { $0.displayFrames } }
    var releaseAllCount: Int { state.withLock { $0.releaseAllCount } }
}

/// `VideoFrameSink` that counts decoded frames and remembers their size, standing in for the Metal view.
final class RecordingFrameSink: VideoFrameSink, @unchecked Sendable {
    private struct State {
        var count = 0
        var lastFrameId: UInt32 = 0
        var nonIncreasing = 0
        var lastSize: (width: Int, height: Int) = (0, 0)
    }
    private let state = Mutex(State())

    func enqueue(_ frame: any RenderableFrame) {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        state.withLock { s in
            if s.count > 0 && frame.frameId <= s.lastFrameId { s.nonIncreasing += 1 }
            s.count += 1
            s.lastFrameId = frame.frameId
            s.lastSize = (width, height)
        }
    }

    var count: Int { state.withLock { $0.count } }
    var lastSize: (width: Int, height: Int) { state.withLock { $0.lastSize } }
    /// Frames delivered out of order (must stay 0: newest-frame-wins, strictly increasing ids).
    var nonIncreasing: Int { state.withLock { $0.nonIncreasing } }
}

/// Keeps references to the sources a session factory created, so tests can inspect / stop them.
final class SourceRecorder: @unchecked Sendable {
    private let sources = Mutex<[SyntheticVideoSource]>([])

    func make(width: Int = 1280, height: Int = 720, config: CaptureConfig) -> SyntheticVideoSource {
        let source = SyntheticVideoSource(sourceWidth: width, sourceHeight: height, config: config,
                                          displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 810))
        sources.withLock { $0.append(source) }
        return source
    }

    var all: [SyntheticVideoSource] { sources.withLock { $0 } }
    var last: SyntheticVideoSource? { all.last }
}

/// In-memory `SessionTransport`: datagrams and control messages go to closures (another pipeline, a recorder).
final class FakeTransport: SessionTransport, @unchecked Sendable {
    private struct State {
        var control: [ControlMessage] = []
        var onControl: (@Sendable (ControlMessage) -> Void)?
        var onDatagrams: (@Sendable ([Data]) -> Void)?
        var accept = true
        var datagramsSent = 0
        var lastMaxQueuedAhead: Int?
    }
    private let state = Mutex(State())
    let maxDatagramSize: Int

    init(maxDatagramSize: Int = WireConstants.defaultMaxDatagramSize) {
        self.maxDatagramSize = maxDatagramSize
    }

    var onControl: (@Sendable (ControlMessage) -> Void)? {
        get { state.withLock { $0.onControl } }
        set { state.withLock { $0.onControl = newValue } }
    }

    var onDatagrams: (@Sendable ([Data]) -> Void)? {
        get { state.withLock { $0.onDatagrams } }
        set { state.withLock { $0.onDatagrams = newValue } }
    }

    /// False makes `sendDatagrams` refuse batches (backpressure).
    var acceptsDatagrams: Bool {
        get { state.withLock { $0.accept } }
        set { state.withLock { $0.accept = newValue } }
    }

    func sendControl(_ message: ControlMessage) {
        let handler = state.withLock { s -> (@Sendable (ControlMessage) -> Void)? in
            s.control.append(message)
            return s.onControl
        }
        handler?(message)
    }

    func sendDatagrams(_ datagrams: [Data]) -> Bool {
        let handler = state.withLock { s -> (@Sendable ([Data]) -> Void)?? in
            guard s.accept else { return .none }
            s.datagramsSent += datagrams.count
            return .some(s.onDatagrams)
        }
        guard let handler else { return false }
        handler?(datagrams)
        return true
    }

    func sendDatagrams(_ datagrams: [Data], maxQueuedAheadBytes: Int) -> Bool {
        state.withLock { $0.lastMaxQueuedAhead = maxQueuedAheadBytes }
        return sendDatagrams(datagrams)
    }

    /// The send-queue bound the Host passed with its latest batch.
    var lastMaxQueuedAhead: Int? { state.withLock { $0.lastMaxQueuedAhead } }

    var pendingDatagramBytes: Int { 0 }
    var controlMessages: [ControlMessage] { state.withLock { $0.control } }
    var datagramsSent: Int { state.withLock { $0.datagramsSent } }
}

extension PermissionChecker {
    static func fixed(screen: Bool, accessibility: Bool) -> PermissionChecker {
        PermissionChecker(screenRecordingGranted: { screen }, accessibilityGranted: { accessibility })
    }

    /// Mutable flags, for tests that revoke a permission mid-session.
    static func dynamic(_ flags: PermissionFlags) -> PermissionChecker {
        PermissionChecker(screenRecordingGranted: { flags.screen }, accessibilityGranted: { flags.accessibility })
    }
}

final class PermissionFlags: @unchecked Sendable {
    private let state = Mutex((screen: true, accessibility: true))
    var screen: Bool {
        get { state.withLock { $0.screen } }
        set { state.withLock { $0.screen = newValue } }
    }
    var accessibility: Bool {
        get { state.withLock { $0.accessibility } }
        set { state.withLock { $0.accessibility = newValue } }
    }
}

enum Events {
    static func mouse(_ type: NSEvent.EventType, clicks: Int = 1, t: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: t, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    static func key(_ type: NSEvent.EventType, _ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                      keyCode: code))
    }
}

extension ControlMessage {
    var isMouseDown: Bool { if case .mouseDown = self { true } else { false } }
    var isMouseUp: Bool { if case .mouseUp = self { true } else { false } }
    var isKeyDown: Bool { if case .keyDown = self { true } else { false } }
    var isKeyUp: Bool { if case .keyUp = self { true } else { false } }
}

/// In-memory pasteboard for clipboard tests: never touches the real clipboard.
@MainActor
final class FakePasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private(set) var contents: [String: Data] = [:]
    var accessBehavior: PasteboardAccessBehavior = .unrestricted
    /// Contents reads return nil (macOS refused: "Don't Allow" or Paste from Other Apps set to Deny).
    var refuseReads = false
    /// Contents reads so far (each is one the real pasteboard may prompt for).
    private(set) var reads = 0
    private(set) var writes = 0

    var types: [String] { contents.keys.sorted() }

    /// Runs once, inside the next contents read, before it returns (another app copying mid-read).
    var beforeNextRead: (() -> Void)?

    func data(forType type: String) -> Data? {
        reads += 1
        if let hook = beforeNextRead {
            beforeNextRead = nil
            hook()
        }
        return refuseReads ? nil : contents[type]
    }

    @discardableResult
    func write(_ representations: [(type: String, data: Data)]) -> Int {
        writes += 1
        contents = Dictionary(representations.map { ($0.type, $0.data) }, uniquingKeysWith: { _, last in last })
        changeCount += 1
        return changeCount
    }

    /// Another app copies something.
    func copy(_ contents: [String: Data]) {
        self.contents = contents
        changeCount += 1
    }

    func copy(text: String) {
        copy([ClipboardPolicy.plainTextType: Data(text.utf8)])
    }

    var text: String? { contents[ClipboardPolicy.plainTextType].map { String(decoding: $0, as: UTF8.self) } }
}

/// Scripted Host pointer for pointer-shape tests: never reads the real cursor.
@MainActor
final class FakeCursorSource: CursorSource {
    var observation: CursorObservation = .unavailable
    private(set) var reads = 0

    func observe() -> CursorObservation {
        reads += 1
        return observation
    }
}

extension CursorSnapshot {
    /// A solid `width × height` pixel image of one premultiplied RGBA color at 2× (so `width / 2` points wide).
    static func solid(width: Int = 8, height: Int = 8, rgba: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255),
                      hotSpot: CGPoint = CGPoint(x: 1, y: 1)) -> CursorSnapshot {
        var data = Data(capacity: width * height * 4)
        for _ in 0..<(width * height) { data.append(contentsOf: [rgba.0, rgba.1, rgba.2, rgba.3]) }
        return CursorSnapshot(pixelWidth: width, pixelHeight: height, rgba: data,
                              pointSize: CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2), hotSpot: hotSpot)
    }
}

/// Stands in for `SystemShortcutTap` (0.1.7): records installs and removals and lets a test feed key events the way
/// the real tap would, without Accessibility or the real keyboard.
@MainActor
final class FakeShortcutTap: SystemShortcutTapping {
    let isArmed: @MainActor () -> Bool
    let deliver: @MainActor (TapKeyEvent) -> Void
    var refuseInstall = false
    private(set) var isInstalled = false
    private(set) var installs = 0
    private(set) var removals = 0

    init(isArmed: @escaping @MainActor () -> Bool = { false },
         deliver: @escaping @MainActor (TapKeyEvent) -> Void = { _ in }) {
        self.isArmed = isArmed
        self.deliver = deliver
    }

    func install() -> Bool {
        guard !refuseInstall else { return false }
        if !isInstalled { installs += 1 }
        isInstalled = true
        return true
    }

    func remove() {
        if isInstalled { removals += 1 }
        isInstalled = false
    }

    /// What the real tap does with a key event: take it only while installed and armed. True if taken.
    @discardableResult
    func press(_ event: TapKeyEvent) -> Bool {
        guard isInstalled, isArmed() else { return false }
        deliver(event)
        return true
    }
}
