import Foundation
import TimeboxUtilities

public enum TimeboxDebugFormatter {
    public static func packetHex(_ data: Data) -> String {
        HexDump.string(from: data)
    }

    public static func packetSummary(name: String, data: Data) -> String {
        "\(name): \(data.count) bytes | \(packetHex(data))"
    }

    public static func checksumHex(fromPacket data: Data) -> String {
        guard data.count >= 4 else {
            return "-"
        }
        return HexDump.string(from: Data(data.dropLast().suffix(2)))
    }

    public static func commandDebugLines(name: String, parameters: [String], data: Data) -> [String] {
        var lines = ["command: \(name)"]
        lines.append(contentsOf: parameters)
        lines.append("packet length: \(data.count) bytes")
        lines.append("checksum: \(checksumHex(fromPacket: data))")
        lines.append("raw packet: \(packetHex(data))")
        return lines
    }
}
