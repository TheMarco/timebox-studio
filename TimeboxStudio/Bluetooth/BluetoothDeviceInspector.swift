import Foundation

#if canImport(IOBluetooth)
import IOBluetooth
#endif

public struct BluetoothServiceInfo: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let rfcommChannelID: UInt8?
    public let l2capPSM: UInt16?
    public let serviceRecordHandle: UInt32?
    public let attributeCount: Int

    public init(
        index: Int,
        name: String,
        rfcommChannelID: UInt8?,
        l2capPSM: UInt16?,
        serviceRecordHandle: UInt32?,
        attributeCount: Int
    ) {
        self.index = index
        self.name = name
        self.rfcommChannelID = rfcommChannelID
        self.l2capPSM = l2capPSM
        self.serviceRecordHandle = serviceRecordHandle
        self.attributeCount = attributeCount
    }
}

public struct BluetoothDeviceInspection: Sendable {
    public let device: TimeboxDevice
    public let sdpStatus: Int32
    public let sdpStatusMessage: String
    public let services: [BluetoothServiceInfo]

    public init(
        device: TimeboxDevice,
        sdpStatus: Int32,
        sdpStatusMessage: String,
        services: [BluetoothServiceInfo]
    ) {
        self.device = device
        self.sdpStatus = sdpStatus
        self.sdpStatusMessage = sdpStatusMessage
        self.services = services
    }
}

public enum BluetoothDeviceInspector {
    public static func inspect(address: String, timeout: TimeInterval = 8) async throws -> BluetoothDeviceInspection {
        #if canImport(IOBluetooth)
        guard let bluetoothDevice = IOBluetoothDevice(addressString: address) else {
            throw TimeboxTransportError.deviceNotFound(address)
        }

        let sdpStatus = try await performSDPQuery(on: bluetoothDevice, timeout: timeout)
        let device = TimeboxDevice(
            name: bluetoothDevice.name ?? "(unnamed)",
            address: bluetoothDevice.addressString ?? address,
            isPaired: bluetoothDevice.isPaired(),
            isConnected: bluetoothDevice.isConnected(),
            source: .bluetooth
        )

        return BluetoothDeviceInspection(
            device: device,
            sdpStatus: sdpStatus,
            sdpStatusMessage: TimeboxTransportError.ioReturnMessage(sdpStatus),
            services: serviceInfo(from: bluetoothDevice)
        )
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    public static func inspect(name: String, timeout: TimeInterval = 8) async throws -> [BluetoothDeviceInspection] {
        let scanResult = BluetoothDeviceScanner.scanPairedDevices(timeout: timeout)
        if scanResult.timedOut {
            throw TimeboxTransportError.scanTimedOut(seconds: scanResult.timeout)
        }

        let matches = scanResult.devices.filter { $0.name.localizedCaseInsensitiveContains(name) }
        if matches.isEmpty {
            throw TimeboxTransportError.deviceNotFound(name)
        }

        var inspections: [BluetoothDeviceInspection] = []
        for match in matches {
            inspections.append(try await inspect(address: match.address, timeout: timeout))
        }
        return inspections
    }

    #if canImport(IOBluetooth)
    private static func performSDPQuery(on device: IOBluetoothDevice, timeout: TimeInterval) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let bridge = SDPQueryDelegateBridge()
            SDPQueryDelegateBridgeStore.shared.retain(bridge)
            bridge.onCompletion = { status in
                guard SDPQueryDelegateBridgeStore.shared.release(bridge) else {
                    return
                }
                continuation.resume(returning: status)
            }

            let result = device.performSDPQuery(bridge)
            guard result == kIOReturnSuccess else {
                SDPQueryDelegateBridgeStore.shared.release(bridge)
                continuation.resume(returning: Int32(result))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard SDPQueryDelegateBridgeStore.shared.release(bridge) else {
                    return
                }
                continuation.resume(throwing: TimeboxTransportError.scanTimedOut(seconds: timeout))
            }
        }
    }

    private static func serviceInfo(from device: IOBluetoothDevice) -> [BluetoothServiceInfo] {
        guard let serviceRecords = device.services as? [IOBluetoothSDPServiceRecord] else {
            return []
        }

        return serviceRecords.enumerated().map { index, serviceRecord in
            var channelID = BluetoothRFCOMMChannelID(0)
            let channelResult = serviceRecord.getRFCOMMChannelID(&channelID)

            var psm = BluetoothL2CAPPSM(0)
            let psmResult = serviceRecord.getL2CAPPSM(&psm)

            var handle = BluetoothSDPServiceRecordHandle(0)
            let handleResult = serviceRecord.getHandle(&handle)

            return BluetoothServiceInfo(
                index: index,
                name: serviceRecord.getServiceName() ?? "(unnamed service)",
                rfcommChannelID: channelResult == kIOReturnSuccess ? UInt8(channelID) : nil,
                l2capPSM: psmResult == kIOReturnSuccess ? UInt16(psm) : nil,
                serviceRecordHandle: handleResult == kIOReturnSuccess ? UInt32(handle) : nil,
                attributeCount: serviceRecord.attributes.count
            )
        }
    }
    #endif
}

#if canImport(IOBluetooth)
private final class SDPQueryDelegateBridge: NSObject, IOBluetoothDeviceAsyncCallbacks, @unchecked Sendable {
    var onCompletion: ((Int32) -> Void)?

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        onCompletion?(Int32(status))
    }

    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    }

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    }
}

private final class SDPQueryDelegateBridgeStore: @unchecked Sendable {
    static let shared = SDPQueryDelegateBridgeStore()

    private let lock = NSLock()
    private var bridges: [ObjectIdentifier: SDPQueryDelegateBridge] = [:]

    func retain(_ bridge: SDPQueryDelegateBridge) {
        lock.lock()
        bridges[ObjectIdentifier(bridge)] = bridge
        lock.unlock()
    }

    @discardableResult
    func release(_ bridge: SDPQueryDelegateBridge) -> Bool {
        lock.lock()
        let removed = bridges.removeValue(forKey: ObjectIdentifier(bridge)) != nil
        lock.unlock()
        return removed
    }
}
#endif
