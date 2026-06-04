import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

public enum ImageToPixelFrameError: LocalizedError, Equatable {
    case cannotLoad(String)
    case cannotCreateContext
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .cannotLoad(let path):
            return "Could not load an image from \(path). Use a PNG/JPEG/BMP/GIF file."
        case .cannotCreateContext:
            return "Could not create a 16x16 drawing context to rasterize the image."
        case .unavailable:
            return "Image conversion requires CoreGraphics (macOS)."
        }
    }
}

/// Loads an image file and rasterizes it to a 16x16 `PixelFrame` using
/// nearest-neighbor scaling, in row-major order with the top-left pixel first.
public enum ImageToPixelFrameConverter {
    public static func loadPixelFrame(path: String) throws -> PixelFrame {
        #if canImport(CoreGraphics)
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageToPixelFrameError.cannotLoad(path)
        }
        return try pixelFrame(from: image)
        #else
        throw ImageToPixelFrameError.unavailable
        #endif
    }

    #if canImport(CoreGraphics)
    /// Rasterize a `CGImage` to a 16x16 `PixelFrame`. `interpolation` defaults to
    /// `.none` (nearest-neighbor, crisp for pixel-art); pass `.high` for photos /
    /// album art so the downscale is smooth.
    public static func pixelFrame(from image: CGImage, interpolation: CGInterpolationQuality = .none) throws -> PixelFrame {
        let width = PixelFrame.width
        let height = PixelFrame.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageToPixelFrameError.cannotCreateContext
        }

        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [PixelRGB] = []
        pixels.reserveCapacity(width * height)
        // CGBitmapContext buffer is top-left origin (buffer[0] = top-left pixel),
        // row-major left-to-right, top-to-bottom — matching the device's pixel order.
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels.append(PixelRGB(
                    red: buffer[offset],
                    green: buffer[offset + 1],
                    blue: buffer[offset + 2]
                ))
            }
        }
        return try PixelFrame(pixels: pixels)
    }
    #endif
}
