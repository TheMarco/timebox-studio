import Foundation

public enum TimeboxChecksum {
    /// Implements PROTOCOL.md "Sending Messages": CRCR is the byte sum of
    /// `LLLL PAYLOAD`, encoded least-significant byte first.
    public static func sum16(_ data: Data) -> UInt16 {
        data.reduce(UInt16(0)) { partialResult, byte in
            partialResult &+ UInt16(byte)
        }
    }

    public static func littleEndianBytes(_ value: UInt16) -> Data {
        Data([
            UInt8(value & 0x00FF),
            UInt8((value >> 8) & 0x00FF)
        ])
    }
}
