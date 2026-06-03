import Foundation

public struct PixelFrame: Codable, Equatable, Sendable {
    public static let width = 16
    public static let height = 16

    public var pixels: [PixelRGB]

    public init(pixels: [PixelRGB]) throws {
        guard pixels.count == Self.width * Self.height else {
            throw PixelFrameError.invalidPixelCount(expected: Self.width * Self.height, actual: pixels.count)
        }
        self.pixels = pixels
    }

    public init(fill color: PixelRGB = PixelRGB(red: 0, green: 0, blue: 0)) {
        self.pixels = Array(repeating: color, count: Self.width * Self.height)
    }
}

public enum PixelFrameError: LocalizedError, Equatable {
    case invalidPixelCount(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidPixelCount(expected, actual):
            return "Pixel frame requires \(expected) pixels, got \(actual)."
        }
    }
}
