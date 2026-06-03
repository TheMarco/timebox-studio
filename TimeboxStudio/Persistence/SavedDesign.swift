import Foundation
import TimeboxKit

public struct SavedDesign: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var frame: PixelFrame

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        frame: PixelFrame = PixelFrame()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.frame = frame
    }
}
