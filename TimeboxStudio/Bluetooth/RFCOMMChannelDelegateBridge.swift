import Foundation

#if canImport(IOBluetooth)
import IOBluetooth

public final class RFCOMMChannelDelegateBridge: NSObject, IOBluetoothRFCOMMChannelDelegate {
    public var onOpenComplete: ((IOReturn) -> Void)?
    public var onClosed: (() -> Void)?
    public var onData: ((Data) -> Void)?
    public var onWriteComplete: ((Int32) -> Void)?

    public override init() {
        super.init()
    }

    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        onOpenComplete?(error)
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        onClosed?()
    }

    public func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else {
            return
        }
        onData?(Data(bytes: dataPointer, count: dataLength))
    }

    public func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        onWriteComplete?(Int32(error))
    }
}
#else
public final class RFCOMMChannelDelegateBridge {
    public init() {
    }
}
#endif
