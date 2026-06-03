import Foundation

public struct TimeboxDevice: Identifiable, Equatable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case bluetooth
        case mock
    }

    public let id: String
    public let name: String
    public let address: String
    public let isPaired: Bool
    public let isConnected: Bool
    public let source: Source

    public init(
        id: String? = nil,
        name: String,
        address: String,
        isPaired: Bool,
        isConnected: Bool,
        source: Source
    ) {
        self.id = id ?? "\(source.rawValue):\(address)"
        self.name = name
        self.address = address
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.source = source
    }

    public var isTimeboxCandidate: Bool {
        let normalizedName = name.lowercased()
        return normalizedName.contains("timebox") && !isTimeboxAudioSide
    }

    public var isTimeboxAudioSide: Bool {
        name.lowercased().contains("timebox") && name.lowercased().contains("audio")
    }

    public var isTimeboxLightSide: Bool {
        name.lowercased().contains("timebox") && name.lowercased().contains("light")
    }

    public static let mock = TimeboxDevice(
        id: "mock:timebox-evo-light",
        name: "Mock Timebox-evo-light",
        address: "00:00:00:00:00:00",
        isPaired: true,
        isConnected: false,
        source: .mock
    )
}
