// swift-tools-version:6.0
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "SwiftDesk",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppUI", targets: ["AppUI"]),
        .executable(name: "SwiftDesk", targets: ["SwiftDeskApp"]),
        .executable(name: "QUICSpike", targets: ["QUICSpike"]),
        .executable(name: "PipelineBench", targets: ["PipelineBench"]),
        .executable(name: "NetBench", targets: ["NetBench"]),
    ],
    targets: [
        // Pure Swift: binary wire protocol, packetization, reassembly, recovery gate. No Apple media/network imports.
        .target(name: "WireProtocol", swiftSettings: swift6),
        // Clock, os_signpost, counters, rolling stats, metrics snapshot.
        .target(name: "DiagnosticsCore", swiftSettings: swift6),
        // Network.framework QUIC (reliable control stream + datagrams), TLS identity/pinning, listener, Bonjour, interface info.
        .target(name: "TransportCore", dependencies: ["WireProtocol", "DiagnosticsCore"], swiftSettings: swift6),
        // ScreenCaptureKit display capture.
        .target(name: "CaptureCore", dependencies: ["DiagnosticsCore"], swiftSettings: swift6),
        // VideoToolbox H.264 encoder/decoder + AVCC utilities.
        .target(name: "CodecCore", dependencies: ["DiagnosticsCore"], swiftSettings: swift6),
        // Metal latest-frame YUV renderer + remote display NSView.
        .target(name: "RenderCore", dependencies: ["DiagnosticsCore"], swiftSettings: swift6),
        // Viewer NSEvent translation + Host CGEvent injection + Accessibility permission.
        .target(name: "InputCore", dependencies: ["WireProtocol"], swiftSettings: swift6),
        // Host/Viewer/Loopback sessions, state machines, adaptation, trust store.
        .target(name: "SessionCore",
                dependencies: ["WireProtocol", "DiagnosticsCore", "TransportCore", "CaptureCore", "CodecCore", "RenderCore", "InputCore"],
                swiftSettings: swift6),
        // SwiftUI screens.
        .target(name: "AppUI", dependencies: ["SessionCore"], swiftSettings: swift6),
        .executableTarget(name: "SwiftDeskApp", dependencies: ["AppUI"], swiftSettings: swift6),
        // Throwaway QUIC stream+datagram validation spike (loopback).
        .executableTarget(name: "QUICSpike", dependencies: ["TransportCore"], swiftSettings: swift6),
        // Milestone A headless bench: synthetic/captured frames -> HW encode -> HW decode, per-stage latency.
        .executableTarget(name: "PipelineBench", dependencies: ["CaptureCore", "CodecCore", "DiagnosticsCore", "WireProtocol"], swiftSettings: swift6),
        // Two-machine network bench: real Host/Viewer sessions over QUIC with a synthetic source, headless.
        .executableTarget(name: "NetBench",
                          dependencies: ["SessionCore", "TransportCore", "CaptureCore", "RenderCore", "DiagnosticsCore", "WireProtocol"],
                          swiftSettings: swift6),

        .testTarget(name: "WireProtocolTests", dependencies: ["WireProtocol"], swiftSettings: swift6),
        .testTarget(name: "DiagnosticsCoreTests", dependencies: ["DiagnosticsCore"], swiftSettings: swift6),
        .testTarget(name: "TransportCoreTests", dependencies: ["TransportCore"], resources: [.copy("Fixtures")],
                    swiftSettings: swift6),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"], swiftSettings: swift6),
        .testTarget(name: "CodecCoreTests", dependencies: ["CodecCore"], swiftSettings: swift6),
        .testTarget(name: "RenderCoreTests", dependencies: ["RenderCore"], swiftSettings: swift6),
        .testTarget(name: "InputCoreTests", dependencies: ["InputCore"], swiftSettings: swift6),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"], swiftSettings: swift6),
    ]
)
