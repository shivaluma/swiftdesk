import AppKit

/// 0.1.6: one Host pointer shape, decoded, ready for `RemoteDisplayView.remotePointer`.
public struct RemotePointerImage: @unchecked Sendable, Equatable {
    /// The Host's id for this shape (stable for the connection).
    public let id: UInt32
    /// The rendition (up to 2× the point size). Immutable.
    public let image: CGImage
    /// Size on the Host, in points.
    public let pointSize: CGSize
    /// Hot spot in points from the top-left corner.
    public let hotSpot: CGPoint

    public init(id: UInt32, image: CGImage, pointSize: CGSize, hotSpot: CGPoint) {
        self.id = id
        self.image = image
        self.pointSize = pointSize
        self.hotSpot = hotSpot
    }

    public static func == (lhs: RemotePointerImage, rhs: RemotePointerImage) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.pointSize == rhs.pointSize && lhs.hotSpot == rhs.hotSpot
    }
}

/// 0.1.6: the pointer `RemoteDisplayView` draws over the video while it captures input.
public enum RemotePointer: Sendable, Equatable {
    /// The local arrow (default; also outside a session, for older Hosts, or with the feature off).
    case standard
    /// No pointer (the Host's is hidden).
    case hidden
    /// The Host pointer's shape.
    case image(RemotePointerImage)
}

/// Builds the `NSCursor`s for remote pointer shapes.
public enum RemotePointerCursor {
    /// The pointer is drawn at the Host's point size times the video's magnification (how many view points show one
    /// Host point), so it matches the remote content around it, clamped to this range (a small window still gets a
    /// pointer that is easy to see) and rounded to 5 % steps.
    public static let scaleRange: ClosedRange<CGFloat> = 0.75...2

    /// Magnification for a video rect showing a Host display of `hostPointSize` points; 1 when either is unknown.
    public static func scale(videoRect: CGRect, hostPointSize: CGSize?) -> CGFloat {
        guard let host = hostPointSize, host.width > 0, host.height > 0, videoRect.width > 0, videoRect.height > 0
        else { return 1 }
        let raw = min(videoRect.width / host.width, videoRect.height / host.height)
        let stepped = (raw * 20).rounded() / 20
        return min(max(stepped, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// An `NSCursor` for `pointer` at `scale`; the image keeps all its pixels (a 2× rendition stays sharp on Retina).
    @MainActor
    public static func cursor(for pointer: RemotePointerImage, scale: CGFloat) -> NSCursor {
        let size = NSSize(width: max(1, pointer.pointSize.width * scale), height: max(1, pointer.pointSize.height * scale))
        let rep = NSBitmapImageRep(cgImage: pointer.image)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let hotSpot = NSPoint(x: min(max(0, pointer.hotSpot.x * scale), max(0, size.width - 1)),
                              y: min(max(0, pointer.hotSpot.y * scale), max(0, size.height - 1)))
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    /// A fully transparent cursor: "hidden" without `NSCursor.hide()`, whose global, counted state would outlive
    /// the view.
    @MainActor
    public static let hidden: NSCursor = {
        // A zeroed bitmap rather than a drawing handler: AppKit may render cursor images off the main thread, where a
        // closure formed here (main-actor isolated) would trap.
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            image.addRepresentation(rep)
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()
}
