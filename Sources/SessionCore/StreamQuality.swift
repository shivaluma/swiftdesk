import CaptureCore

/// The Host's picture-quality choice (Host screen › Display › Quality). Applies to the next session, like the display
/// choice.
///
/// - **Sharp** (default): native resolution up to 1920×1080 — a 1600×900 display streams at exactly 1600×900, so the
///   Viewer can show it pixel for pixel — with the bitrate scaled to the picture (≈ 8 Mbps at 1600×900@60). It still
///   steps down to 1280×720, then 960×540, on a weak link.
/// - **Balanced**: at most 1280×720 and 1–5 Mbps, exactly what SwiftDesk streamed before 0.1.3. For weak Wi-Fi.
public enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case sharp
    case balanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sharp: "Sharp"
        case .balanced: "Balanced"
        }
    }

    /// Picker label, e.g. "Sharp — native resolution, up to 1920×1080".
    public var label: String {
        let top = topRung
        switch self {
        case .sharp: return "Sharp — native resolution, up to \(top.width)×\(top.height)"
        case .balanced: return "Balanced — up to \(top.width)×\(top.height)"
        }
    }

    /// The ladder's first rung (the capture bounds a session starts with).
    public var topRung: AdaptationController.Rung {
        adaptation(base: .init()).ladder.first ?? AdaptationController.Rung(width: 1280, height: 720, fps: 60)
    }

    /// `base` (the Host's configured adaptation, which is the Sharp profile) with this quality's ladder and bitrate
    /// range. Timing and congestion thresholds are kept, so tests and benches that tune them keep working.
    public func adaptation(base: AdaptationController.Configuration) -> AdaptationController.Configuration {
        switch self {
        case .sharp:
            return base
        case .balanced:
            let balanced = AdaptationController.Configuration.balanced
            var c = base
            c.ladder = balanced.ladder
            c.minBitrateKbps = balanced.minBitrateKbps
            c.maxBitrateKbps = balanced.maxBitrateKbps
            c.initialBitrateKbps = balanced.initialBitrateKbps
            c.scalesBitrateToPicture = balanced.scalesBitrateToPicture
            return c
        }
    }

    /// Size the stream starts at on a display of `pixelWidth × pixelHeight` backing pixels (aspect preserved, never
    /// upscaled): 1600×900 for a 1600×900 display on Sharp, 1280×720 on Balanced. nil for an unknown display.
    public func streamSize(displayPixelWidth: Int, displayPixelHeight: Int,
                           base: AdaptationController.Configuration = .init()) -> (width: Int, height: Int)? {
        guard displayPixelWidth > 0, displayPixelHeight > 0, let rung = adaptation(base: base).ladder.first else {
            return nil
        }
        let size = CaptureGeometry.fit(sourceWidth: displayPixelWidth, sourceHeight: displayPixelHeight,
                                       maxWidth: rung.width, maxHeight: rung.height)
        return size.width > 0 && size.height > 0 ? size : nil
    }
}
