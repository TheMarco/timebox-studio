import Foundation
import TimeboxUtilities

#if canImport(IOBluetooth)
import IOBluetooth
#endif

#if canImport(IOBluetooth)
private final class CompletionFlag {
    var isDone = false
}
#endif

/// IOBluetooth (Classic) delivers RFCOMM open/write callbacks through the
/// **main** CFRunLoop, not a dispatch queue and not an arbitrary thread's run
/// loop. The fix has two entry styles:
///
/// - CLI (no run loop running): `connectPumpingRunLoop` / `writePumpingRunLoop`
///   must be called on the main thread; they start the async IOBluetooth op and
///   pump the main run loop until the delegate fires.
/// - App (main run loop already running via AppKit): the async `connect` /
///   `write` protocol methods hop to the main thread, start the op, and resume a
///   continuation from the delegate — no manual pumping.
public final class IOBluetoothTimeboxTransport: TimeboxTransport, TimeboxTransportDiagnostics, @unchecked Sendable {
    public private(set) var isConnected = false
    public private(set) var lastRFCOMMChannelID: UInt8?

    #if canImport(IOBluetooth)
    private var bluetoothDevice: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var delegateBridge: RFCOMMChannelDelegateBridge?

    private let openTimeout: TimeInterval = 15
    private let writeTimeout: TimeInterval = 10
    // kIOReturnTimeout, surfaced when no run-loop callback arrives in time.
    private let timeoutCode = Int32(bitPattern: 0xE00002D6 as UInt32)
    #endif

    public init() {
    }

    // MARK: - Async protocol conformance (SwiftUI app; main run loop running)

    public func connect(to device: TimeboxDevice) async throws {
        try await connectViaRunningRunLoop(device, channelID: nil)
    }

    public func connect(to device: TimeboxDevice, channelID: UInt8) async throws {
        try await connectViaRunningRunLoop(device, channelID: channelID)
    }

    public func write(_ data: Data) async throws {
        #if canImport(IOBluetooth)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.startWrite(data, continuation: continuation)
            }
        }
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    public func disconnect() {
        #if canImport(IOBluetooth)
        _ = channel?.close()
        channel = nil
        bluetoothDevice = nil
        delegateBridge = nil
        #endif
        isConnected = false
    }

    /// Keep the connection open and the run loop serviced for `milliseconds`,
    /// e.g. to let the device finish processing a just-sent command (and to
    /// receive any ACK) before the channel is torn down. Call on the main thread.
    public func waitPumpingRunLoop(milliseconds: Int) {
        #if canImport(IOBluetooth)
        guard milliseconds > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, true)
        }
        #endif
    }

    // MARK: - Synchronous, run-loop-pumping entry points (CLI; call on main thread)

    public func connectPumpingRunLoop(to device: TimeboxDevice, channelID: UInt8?) throws {
        #if canImport(IOBluetooth)
        guard !device.address.isEmpty, device.address != "unknown-address" else {
            throw TimeboxTransportError.deviceAddressMissing(device.name)
        }

        let candidates = resolveCandidates(address: device.address, preferred: channelID)
        var lastFailure: TimeboxTransportError?
        for channelID in candidates {
            do {
                try openPumping(address: device.address, channelID: channelID)
                return
            } catch let error as TimeboxTransportError {
                lastFailure = error
            }
        }
        throw lastFailure ?? TimeboxTransportError.noRFCOMMChannel(device.name)
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    public func writePumpingRunLoop(_ data: Data) throws {
        #if canImport(IOBluetooth)
        guard isConnected, let channel, let bridge = delegateBridge else {
            throw TimeboxTransportError.notConnected
        }
        guard data.count <= Int(UInt16.max) else {
            throw TimeboxTransportError.payloadTooLarge(data.count)
        }

        var status: IOReturn = kIOReturnError
        let flag = CompletionFlag()
        let length = UInt16(data.count)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        defer { buffer.deallocate() }

        bridge.onWriteComplete = { result in
            status = result
            flag.isDone = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        let beginResult = channel.writeAsync(buffer, length: length, refcon: nil)
        if beginResult != kIOReturnSuccess {
            throw TimeboxTransportError.writeFailed(
                code: Int32(beginResult),
                message: TimeboxTransportError.ioReturnMessage(Int32(beginResult))
            )
        }

        pumpRunLoop(until: flag, timeout: writeTimeout)

        guard flag.isDone else {
            throw TimeboxTransportError.writeFailed(code: timeoutCode, message: "RFCOMM write timed out waiting for the write-complete callback")
        }
        guard status == kIOReturnSuccess else {
            throw TimeboxTransportError.writeFailed(code: Int32(status), message: TimeboxTransportError.ioReturnMessage(Int32(status)))
        }
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    #if canImport(IOBluetooth)
    // MARK: - Core open (must run on the main thread)

    /// Starts the async RFCOMM open and wires `onOpenComplete` to `onComplete`.
    /// Throws synchronously only if the open could not even be started.
    private func beginOpen(address: String, channelID: UInt8, onComplete: @escaping (IOReturn) -> Void) throws {
        guard let device = IOBluetoothDevice(addressString: address) else {
            throw TimeboxTransportError.deviceNotFound(address)
        }

        let bridge = RFCOMMChannelDelegateBridge()
        bridge.onOpenComplete = onComplete
        bridge.onClosed = { [weak self] in
            self?.isConnected = false
            self?.channel = nil
        }

        var openedChannel: IOBluetoothRFCOMMChannel?
        let beginResult = device.openRFCOMMChannelAsync(
            &openedChannel,
            withChannelID: BluetoothRFCOMMChannelID(channelID),
            delegate: bridge
        )
        guard beginResult == kIOReturnSuccess else {
            throw TimeboxTransportError.openChannelFailed(
                channelID: channelID,
                code: Int32(beginResult),
                message: TimeboxTransportError.ioReturnMessage(Int32(beginResult))
            )
        }

        // Retain device/channel/bridge while the async open completes.
        bluetoothDevice = device
        channel = openedChannel
        delegateBridge = bridge
    }

    private func openPumping(address: String, channelID: UInt8) throws {
        var status: IOReturn = kIOReturnError
        let flag = CompletionFlag()

        try beginOpen(address: address, channelID: channelID) { result in
            status = result
            flag.isDone = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        pumpRunLoop(until: flag, timeout: openTimeout)

        guard flag.isDone else {
            cleanup()
            throw TimeboxTransportError.openChannelFailed(
                channelID: channelID,
                code: timeoutCode,
                message: "RFCOMM open timed out waiting for the channel-open callback"
            )
        }
        guard status == kIOReturnSuccess else {
            cleanup()
            throw TimeboxTransportError.openChannelFailed(
                channelID: channelID,
                code: Int32(status),
                message: TimeboxTransportError.ioReturnMessage(Int32(status))
            )
        }

        lastRFCOMMChannelID = channelID
        isConnected = true
    }

    private func pumpRunLoop(until flag: CompletionFlag, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isDone && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }
    }

    // MARK: - Core async (app; relies on the already-running main run loop)

    private func connectViaRunningRunLoop(_ device: TimeboxDevice, channelID: UInt8?) async throws {
        #if canImport(IOBluetooth)
        guard !device.address.isEmpty, device.address != "unknown-address" else {
            throw TimeboxTransportError.deviceAddressMissing(device.name)
        }

        let candidates = resolveCandidates(address: device.address, preferred: channelID)
        var lastFailure: TimeboxTransportError?
        for channelID in candidates {
            do {
                try await openViaRunningRunLoop(address: device.address, channelID: channelID)
                return
            } catch let error as TimeboxTransportError {
                lastFailure = error
            }
        }
        throw lastFailure ?? TimeboxTransportError.noRFCOMMChannel(device.name)
        #else
        throw TimeboxTransportError.bluetoothUnavailable
        #endif
    }

    private func openViaRunningRunLoop(address: String, channelID: UInt8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let flag = CompletionFlag()
                do {
                    try self.beginOpen(address: address, channelID: channelID) { status in
                        guard !flag.isDone else { return }
                        flag.isDone = true
                        if status == kIOReturnSuccess {
                            self.lastRFCOMMChannelID = channelID
                            self.isConnected = true
                            continuation.resume()
                        } else {
                            self.cleanup()
                            continuation.resume(throwing: TimeboxTransportError.openChannelFailed(
                                channelID: channelID,
                                code: Int32(status),
                                message: TimeboxTransportError.ioReturnMessage(Int32(status))
                            ))
                        }
                    }
                } catch {
                    flag.isDone = true
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.openTimeout) {
                    guard !flag.isDone else { return }
                    flag.isDone = true
                    self.cleanup()
                    continuation.resume(throwing: TimeboxTransportError.openChannelFailed(
                        channelID: channelID,
                        code: self.timeoutCode,
                        message: "RFCOMM open timed out waiting for the channel-open callback"
                    ))
                }
            }
        }
    }

    private func startWrite(_ data: Data, continuation: CheckedContinuation<Void, Error>) {
        guard isConnected, let channel, let bridge = delegateBridge else {
            continuation.resume(throwing: TimeboxTransportError.notConnected)
            return
        }
        guard data.count <= Int(UInt16.max) else {
            continuation.resume(throwing: TimeboxTransportError.payloadTooLarge(data.count))
            return
        }

        let flag = CompletionFlag()
        let length = UInt16(data.count)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)

        bridge.onWriteComplete = { status in
            guard !flag.isDone else { return }
            flag.isDone = true
            buffer.deallocate()
            if status == kIOReturnSuccess {
                continuation.resume()
            } else {
                continuation.resume(throwing: TimeboxTransportError.writeFailed(
                    code: Int32(status),
                    message: TimeboxTransportError.ioReturnMessage(Int32(status))
                ))
            }
        }

        let beginResult = channel.writeAsync(buffer, length: length, refcon: nil)
        if beginResult != kIOReturnSuccess, !flag.isDone {
            flag.isDone = true
            buffer.deallocate()
            continuation.resume(throwing: TimeboxTransportError.writeFailed(
                code: Int32(beginResult),
                message: TimeboxTransportError.ioReturnMessage(Int32(beginResult))
            ))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeout) {
            guard !flag.isDone else { return }
            flag.isDone = true
            buffer.deallocate()
            continuation.resume(throwing: TimeboxTransportError.writeFailed(
                code: self.timeoutCode,
                message: "RFCOMM write timed out waiting for the write-complete callback"
            ))
        }
    }

    // MARK: - Helpers

    private func resolveCandidates(address: String, preferred: UInt8?) -> [UInt8] {
        if let preferred {
            return [preferred]
        }
        guard let device = IOBluetoothDevice(addressString: address) else {
            return [1]
        }
        // Resolve the channel the way the official app does: the Serial Port
        // Profile (UUID 0x1101) record from the device's own SDP. Works for any
        // user's Timebox regardless of its Bluetooth address or channel number.
        if let sppChannel = serialPortChannel(device: device) {
            return [sppChannel]
        }
        let discovered = discoverChannelIDs(device: device)
        return discovered.isEmpty ? [1] : discovered
    }

    private func serialPortChannel(device: IOBluetoothDevice) -> UInt8? {
        let sppUUID = IOBluetoothSDPUUID(uuid16: 0x1101) // Serial Port Profile
        guard let record = device.getServiceRecord(for: sppUUID) else {
            return nil
        }
        var channelID = BluetoothRFCOMMChannelID(0)
        if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, channelID > 0 {
            return UInt8(channelID)
        }
        return nil
    }

    private func cleanup() {
        let closingChannel = channel
        DispatchQueue.main.async { _ = closingChannel?.close() }
        channel = nil
        bluetoothDevice = nil
        delegateBridge = nil
        isConnected = false
    }

    private func discoverChannelIDs(device: IOBluetoothDevice) -> [UInt8] {
        guard let serviceRecords = device.services as? [IOBluetoothSDPServiceRecord] else {
            return []
        }

        var channelIDs: [UInt8] = []
        for serviceRecord in serviceRecords {
            var channelID = BluetoothRFCOMMChannelID(0)
            if serviceRecord.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
               channelID > 0, !channelIDs.contains(UInt8(channelID)) {
                channelIDs.append(UInt8(channelID))
            }
        }
        return channelIDs
    }
    #endif
}
