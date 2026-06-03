import Foundation
import TimeboxKit
import TimeboxUtilities

public final class MockTimeboxTransport: TimeboxTransport, TimeboxTransportDiagnostics {
    public private(set) var isConnected = false
    public private(set) var lastRFCOMMChannelID: UInt8? = 1

    public init() {
    }

    public func connect(to device: TimeboxDevice) async throws {
        isConnected = true
        print("[MockTimeboxTransport] connected to \(device.name) (\(device.address))")
    }

    public func disconnect() {
        isConnected = false
        print("[MockTimeboxTransport] disconnected")
    }

    public func write(_ data: Data) async throws {
        guard isConnected else {
            throw TimeboxTransportError.notConnected
        }
        print("[MockTimeboxTransport] write \(data.count) bytes: \(HexDump.string(from: data))")
    }
}
