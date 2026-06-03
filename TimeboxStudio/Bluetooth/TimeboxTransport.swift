import Foundation

#if canImport(IOKit)
import IOKit
#endif

public protocol TimeboxTransport: AnyObject {
    var isConnected: Bool { get }

    func connect(to device: TimeboxDevice) async throws
    func disconnect()
    func write(_ data: Data) async throws
}

public protocol TimeboxTransportDiagnostics {
    var lastRFCOMMChannelID: UInt8? { get }
}

public enum TimeboxTransportError: LocalizedError, Equatable {
    case bluetoothUnavailable
    case deviceAddressMissing(String)
    case deviceNotFound(String)
    case noRFCOMMChannel(String)
    case scanTimedOut(seconds: Double)
    case inquiryFailed(code: Int32, message: String)
    case openChannelFailed(channelID: UInt8, code: Int32, message: String)
    case writeFailed(code: Int32, message: String)
    case payloadTooLarge(Int)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "IOBluetooth is unavailable on this system."
        case .deviceAddressMissing(let name):
            return "Bluetooth device '\(name)' does not have a usable address."
        case .deviceNotFound(let address):
            return "Could not find an IOBluetoothDevice for address \(address). Make sure it is paired with macOS."
        case .noRFCOMMChannel(let name):
            return "No RFCOMM channel could be discovered for '\(name)'. The light-side Timebox device may not be paired, may be asleep, or may expose services only after reconnecting."
        case .scanTimedOut(let seconds):
            return "Bluetooth device scan timed out after \(String(format: "%.1f", seconds)) seconds. macOS may be waiting on Bluetooth privacy permission, or IOBluetooth may be blocked by the current host process."
        case let .inquiryFailed(code, message):
            return "Bluetooth inquiry failed. IOReturn \(Self.formatIOReturn(code)) (\(message))."
        case let .openChannelFailed(channelID, code, message):
            return "Failed to open RFCOMM channel \(channelID). IOReturn \(Self.formatIOReturn(code)) (\(message))."
        case let .writeFailed(code, message):
            return "Failed to write bytes to RFCOMM channel. IOReturn \(Self.formatIOReturn(code)) (\(message))."
        case .payloadTooLarge(let count):
            return "Payload is \(count) bytes. IOBluetooth RFCOMM writeSync length is limited to 65535 bytes."
        case .notConnected:
            return "No Timebox RFCOMM channel is connected."
        }
    }

    public static func formatIOReturn(_ code: Int32) -> String {
        let unsigned = UInt32(bitPattern: code)
        return "\(code) / 0x\(String(format: "%08X", unsigned))"
    }

    public static func ioReturnMessage(_ code: Int32) -> String {
        #if canImport(IOKit)
        switch code {
        case Int32(kIOReturnSuccess):
            return "success"
        case Int32(kIOReturnNotOpen):
            return "channel is not open"
        case Int32(kIOReturnNoDevice):
            return "device is unavailable"
        case Int32(kIOReturnNotPermitted):
            return "Bluetooth access is not permitted"
        case Int32(kIOReturnUnsupported):
            return "operation is unsupported"
        case Int32(kIOReturnBadArgument):
            return "bad argument"
        default:
            return "unknown IOKit error"
        }
        #else
        return "IOKit is unavailable"
        #endif
    }
}
