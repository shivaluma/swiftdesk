import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// The address book's thumbnail of a remote screen (0.1.8): the last decoded frame of a session, downscaled to at most
/// `maxPixels` on its long edge and JPEG-encoded.
///
/// Runs once per ended session, off the main actor (a detached task in `ViewerSession`); never per frame. The decoded
/// buffer (420v, IOSurface-backed) is converted by `VTCreateCGImageFromCVPixelBuffer`, then drawn into a small sRGB
/// bitmap and written by ImageIO. Images are never logged.
public enum SessionThumbnail {
    public static let maxPixels = 320
    public static let jpegQuality = 0.7

    /// JPEG data of `pixelBuffer` scaled to fit `maxPixels`, or nil if the buffer cannot be converted.
    public static func jpeg(from pixelBuffer: CVPixelBuffer, maxPixels: Int = maxPixels,
                            quality: Double = jpegQuality) -> Data? {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == noErr,
              let image else { return nil }
        return jpeg(from: image, maxPixels: maxPixels, quality: quality)
    }

    public static func jpeg(from image: CGImage, maxPixels: Int = maxPixels, quality: Double = jpegQuality) -> Data? {
        let size = scaledSize(width: image.width, height: image.height, maxPixels: maxPixels)
        guard size.width > 0, size.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Aspect-preserving size whose long edge is at most `maxPixels` (never upscaled, at least 1×1).
    public static func scaledSize(width: Int, height: Int, maxPixels: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxPixels > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        guard longEdge > maxPixels else { return (width, height) }
        let scale = Double(maxPixels) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
