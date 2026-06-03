import Foundation

#if canImport(IOBluetooth)
@preconcurrency import IOBluetooth
#endif

public struct BluetoothScanResult: Sendable {
    public let devices: [TimeboxDevice]
    public let timedOut: Bool
    public let timeout: TimeInterval

    public init(devices: [TimeboxDevice], timedOut: Bool, timeout: TimeInterval) {
        self.devices = devices
        self.timedOut = timedOut
        self.timeout = timeout
    }
}

public enum BluetoothDeviceScanner {
    public static func scanPairedDevices(includeMock: Bool = false, timeout: TimeInterval = 5) -> BluetoothScanResult {
        if includeMock {
            return BluetoothScanResult(devices: [.mock], timedOut: false, timeout: timeout)
        }

        #if canImport(IOBluetooth)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var devices: [TimeboxDevice] = []

        DispatchQueue.global(qos: .userInitiated).async {
            let scannedDevices = scanPairedDevicesBlocking()
            lock.lock()
            devices = scannedDevices
            lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return BluetoothScanResult(devices: [], timedOut: true, timeout: timeout)
        }

        lock.lock()
        let scannedDevices = devices
        lock.unlock()
        return BluetoothScanResult(devices: scannedDevices, timedOut: false, timeout: timeout)
        #else
        return BluetoothScanResult(devices: [], timedOut: false, timeout: timeout)
        #endif
    }

    public static func pairedDevices(includeMock: Bool = false) -> [TimeboxDevice] {
        scanPairedDevices(includeMock: includeMock).devices
    }

    public static func scanNearbyDevices(inquiryLength: UInt8 = 12, timeout: TimeInterval = 26) async throws -> [TimeboxDevice] {
        #if canImport(IOBluetooth)
        try scanNearbyDevicesWithRunLoop(inquiryLength: inquiryLength, timeout: timeout)
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    public static func firstTimeboxCandidate(named name: String? = nil, includeMock: Bool = false) throws -> TimeboxDevice? {
        let result = scanPairedDevices(includeMock: includeMock)
        if result.timedOut {
            throw TimeboxTransportError.scanTimedOut(seconds: result.timeout)
        }

        if let name, !name.isEmpty {
            return result.devices.first { $0.name.localizedCaseInsensitiveContains(name) }
        }
        return result.devices.first { $0.isTimeboxCandidate }
    }

    #if canImport(IOBluetooth)
    private static func scanPairedDevicesBlocking() -> [TimeboxDevice] {
        var devices: [TimeboxDevice] = []

        if let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            devices = pairedDevices.map { device in
                let address = device.addressString ?? "unknown-address"
                let name = device.name ?? "(unnamed)"
                return TimeboxDevice(
                    name: name,
                    address: address,
                    isPaired: device.isPaired(),
                    isConnected: device.isConnected(),
                    source: .bluetooth
                )
            }
            .sorted { left, right in
                if left.isTimeboxCandidate != right.isTimeboxCandidate {
                    return left.isTimeboxCandidate && !right.isTimeboxCandidate
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
        }

        return devices
    }

    private static func scanNearbyDevicesWithRunLoop(inquiryLength: UInt8, timeout: TimeInterval) throws -> [TimeboxDevice] {
        let bridge = DeviceInquiryDelegateBridge()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: bridge) else {
            throw TimeboxTransportError.bluetoothUnavailable
        }

        bridge.inquiry = inquiry
        inquiry.inquiryLength = inquiryLength
        inquiry.searchType = IOBluetoothDeviceSearchTypes(kIOBluetoothDeviceSearchClassic.rawValue)
        inquiry.updateNewDeviceNames = true

        let startResult = inquiry.start()
        guard startResult == kIOReturnSuccess else {
            throw TimeboxTransportError.inquiryFailed(
                code: Int32(startResult),
                message: TimeboxTransportError.ioReturnMessage(Int32(startResult))
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !bridge.isComplete && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        guard bridge.isComplete else {
            _ = inquiry.stop()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3))
            throw TimeboxTransportError.scanTimedOut(seconds: timeout)
        }

        let status = bridge.completionStatus ?? Int32(kIOReturnSuccess)
        guard status == Int32(kIOReturnSuccess) else {
            throw TimeboxTransportError.inquiryFailed(
                code: status,
                message: TimeboxTransportError.ioReturnMessage(status)
            )
        }

        let foundDevices = (inquiry.foundDevices() as? [IOBluetoothDevice]) ?? []
        return normalizedDevices(foundDevices + bridge.snapshot())
    }

    private static func normalizedDevices(_ bluetoothDevices: [IOBluetoothDevice]) -> [TimeboxDevice] {
        var devicesByAddress: [String: TimeboxDevice] = [:]

        for device in bluetoothDevices {
            let address = device.addressString ?? "unknown-address"
            devicesByAddress[address] = TimeboxDevice(
                name: device.name ?? address,
                address: address,
                isPaired: device.isPaired(),
                isConnected: device.isConnected(),
                source: .bluetooth
            )
        }

        return devicesByAddress.values.sorted { left, right in
            if left.isTimeboxCandidate != right.isTimeboxCandidate {
                return left.isTimeboxCandidate && !right.isTimeboxCandidate
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
    #endif
}

#if canImport(IOBluetooth)
private final class DeviceInquiryDelegateBridge: NSObject, IOBluetoothDeviceInquiryDelegate, @unchecked Sendable {
    var inquiry: IOBluetoothDeviceInquiry?
    var onComplete: (([IOBluetoothDevice], Int32, Bool) -> Void)?

    private let lock = NSLock()
    private var devicesByAddress: [String: IOBluetoothDevice] = [:]
    private var didComplete = false
    private var status: Int32?
    private var aborted = false

    var isComplete: Bool {
        lock.lock()
        let value = didComplete
        lock.unlock()
        return value
    }

    var completionStatus: Int32? {
        lock.lock()
        let value = status
        lock.unlock()
        return value
    }

    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        store(device)
    }

    func deviceInquiryUpdatingDeviceNamesStarted(_ sender: IOBluetoothDeviceInquiry!, devicesRemaining: UInt32) {
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry!,
        device: IOBluetoothDevice!,
        devicesRemaining: UInt32
    ) {
        store(device)
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        let foundDevices = (sender.foundDevices() as? [IOBluetoothDevice]) ?? snapshot()
        for device in foundDevices {
            store(device)
        }
        markComplete(status: Int32(error), aborted: aborted)
        onComplete?(snapshot(), Int32(error), aborted)
    }

    private func store(_ device: IOBluetoothDevice?) {
        guard let device else {
            return
        }
        let address = device.addressString ?? UUID().uuidString
        lock.lock()
        devicesByAddress[address] = device
        lock.unlock()
    }

    fileprivate func snapshot() -> [IOBluetoothDevice] {
        lock.lock()
        let devices = Array(devicesByAddress.values)
        lock.unlock()
        return devices
    }

    private func markComplete(status: Int32, aborted: Bool) {
        lock.lock()
        self.didComplete = true
        self.status = status
        self.aborted = aborted
        lock.unlock()
    }
}
#endif
