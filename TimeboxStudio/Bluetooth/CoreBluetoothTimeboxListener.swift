import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public struct BLEListenSummary: Equatable, Sendable {
    public let peripheralID: UUID
    public let name: String
    public let subscribedCharacteristics: [String]
    public let notificationCount: Int
    public let readCount: Int
    public let writesAttempted: Int

    public init(
        peripheralID: UUID,
        name: String,
        subscribedCharacteristics: [String],
        notificationCount: Int,
        readCount: Int,
        writesAttempted: Int
    ) {
        self.peripheralID = peripheralID
        self.name = name
        self.subscribedCharacteristics = subscribedCharacteristics
        self.notificationCount = notificationCount
        self.readCount = readCount
        self.writesAttempted = writesAttempted
    }
}

/// One write to perform after notifications are enabled, then dwell to watch
/// the panel / capture any reply before the next step.
public struct BLEWriteStep: Sendable {
    public let data: Data
    public let characteristicUUID: String?
    public let writeModePreference: BLEWriteModePreference
    public let dwellMilliseconds: Int
    public let label: String

    public init(
        data: Data,
        characteristicUUID: String?,
        writeModePreference: BLEWriteModePreference,
        dwellMilliseconds: Int,
        label: String
    ) {
        self.data = data
        self.characteristicUUID = characteristicUUID
        self.writeModePreference = writeModePreference
        self.dwellMilliseconds = dwellMilliseconds
        self.label = label
    }
}

/// Persistent BLE diagnostic: connects, subscribes to every notify/indicate
/// characteristic, optionally runs a sequence of writes *after* notifications
/// are enabled, and streams back any value the device reports. This is the
/// tool that proves whether the Transparent UART pipe actually feeds the
/// Timebox protocol parser, and which characteristic it listens on (writes
/// alone only prove the GATT layer accepted bytes).
public enum CoreBluetoothTimeboxListener {
    /// Subscribe, optionally send one packet, then keep listening for `listenSeconds`.
    public static func listen(
        identifier: UUID?,
        name: String?,
        serviceUUID: String? = nil,
        listenSeconds: UInt8 = 20,
        send: Data? = nil,
        characteristicUUID: String? = nil,
        writeModePreference: BLEWriteModePreference = .automatic,
        onEvent: @escaping @Sendable (String) -> Void
    ) async throws -> BLEListenSummary {
        let steps = send.map {
            [BLEWriteStep(
                data: $0,
                characteristicUUID: characteristicUUID,
                writeModePreference: writeModePreference,
                dwellMilliseconds: 0,
                label: "send"
            )]
        } ?? []
        return try await run(
            identifier: identifier,
            name: name,
            serviceUUID: serviceUUID,
            listenSeconds: listenSeconds,
            steps: steps,
            finishAfterSteps: false,
            onEvent: onEvent
        )
    }

    /// Write `packet` to each candidate characteristic in turn (each supported
    /// write mode), dwelling between writes so the operator can watch the panel
    /// and any reply is attributed to the preceding write. Finishes shortly
    /// after the last write.
    public static func probe(
        identifier: UUID?,
        name: String?,
        serviceUUID: String? = nil,
        packet: Data,
        characteristicUUIDs: [String],
        dwellMilliseconds: Int = 3000,
        onEvent: @escaping @Sendable (String) -> Void
    ) async throws -> BLEListenSummary {
        var steps: [BLEWriteStep] = []
        for uuid in characteristicUUIDs {
            for mode in [BLEWriteModePreference.withoutResponse, .withResponse] {
                steps.append(BLEWriteStep(
                    data: packet,
                    characteristicUUID: uuid,
                    writeModePreference: mode,
                    dwellMilliseconds: dwellMilliseconds,
                    label: "\(shortUUID(uuid)) \(mode == .withResponse ? "w/resp" : "no-resp")"
                ))
            }
        }
        let dwellSeconds = max(1, dwellMilliseconds / 1000)
        let window = min(255, 6 + steps.count * dwellSeconds)
        return try await run(
            identifier: identifier,
            name: name,
            serviceUUID: serviceUUID,
            listenSeconds: UInt8(window),
            steps: steps,
            finishAfterSteps: true,
            onEvent: onEvent
        )
    }

    private static func shortUUID(_ uuid: String) -> String {
        String(uuid.prefix(13))
    }

    private static func run(
        identifier: UUID?,
        name: String?,
        serviceUUID: String?,
        listenSeconds: UInt8,
        steps: [BLEWriteStep],
        finishAfterSteps: Bool,
        onEvent: @escaping @Sendable (String) -> Void
    ) async throws -> BLEListenSummary {
        #if canImport(CoreBluetooth)
        guard identifier != nil || name != nil || serviceUUID != nil else {
            throw BLEClientError.missingTarget
        }
        let session = BLEListenSession(
            identifier: identifier,
            name: name,
            serviceUUID: serviceUUID,
            listenSeconds: listenSeconds,
            steps: steps,
            finishAfterSteps: finishAfterSteps,
            onEvent: onEvent
        )
        return try await session.run()
        #else
        throw BLEScanError.unavailable
        #endif
    }
}

#if canImport(CoreBluetooth)
private final class BLEListenSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let identifier: UUID?
    private let name: String?
    private let serviceUUID: String?
    private let serviceCBUUID: CBUUID?
    private let listenSeconds: UInt8
    private let steps: [BLEWriteStep]
    private let finishAfterSteps: Bool
    private let onEvent: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.timeboxstudio.ble-listener")
    private let start = Date()

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var continuation: CheckedContinuation<BLEListenSummary, Error>?
    private var didFinish = false

    private var pendingCharacteristicServiceUUIDs = Set<String>()
    private var discoveredServices: [CBService] = []
    private var characteristicsByService: [String: [CBCharacteristic]] = [:]
    private var pendingNotifyEnables = 0
    private var didStartSteps = false
    private var currentStepLabel = "-"

    private var subscribed: [String] = []
    private var notificationCount = 0
    private var readCount = 0
    private var writesAttempted = 0

    init(
        identifier: UUID?,
        name: String?,
        serviceUUID: String?,
        listenSeconds: UInt8,
        steps: [BLEWriteStep],
        finishAfterSteps: Bool,
        onEvent: @escaping @Sendable (String) -> Void
    ) {
        self.identifier = identifier
        self.name = name
        self.serviceUUID = serviceUUID
        self.serviceCBUUID = serviceUUID.map(CBUUID.init(string:))
        self.listenSeconds = listenSeconds
        self.steps = steps
        self.finishAfterSteps = finishAfterSteps
        self.onEvent = onEvent
        super.init()
    }

    func run() async throws -> BLEListenSummary {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    private func emit(_ line: String) {
        let elapsed = Date().timeIntervalSince(start)
        onEvent(String(format: "[+%6.3fs] ", elapsed) + line)
    }

    private func matches(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if let identifier, peripheral.identifier == identifier {
            return true
        }
        if let name {
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let fields = [peripheral.name, advertisedName].compactMap { $0?.lowercased() }
            if fields.contains(where: { $0.contains(name.lowercased()) }) {
                return true
            }
        }
        if let serviceCBUUID {
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
            return advertised?.contains(serviceCBUUID) == true
        }
        return false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let identifier,
               let retrieved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
                connect(to: retrieved)
                return
            }
            emit("scanning for target...")
            central.scanForPeripherals(
                withServices: serviceCBUUID.map { [$0] },
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .poweredOff:
            finish(error: BLEScanError.poweredOff)
        case .unsupported:
            finish(error: BLEScanError.unsupported)
        case .unauthorized:
            finish(error: BLEScanError.unauthorized)
        case .resetting:
            finish(error: BLEScanError.resetting)
        case .unknown:
            break
        @unknown default:
            finish(error: BLEScanError.unknownState("\(central.state.rawValue)"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matches(peripheral: peripheral, advertisementData: advertisementData) else {
            return
        }
        central.stopScan()
        connect(to: peripheral)
    }

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        emit("connecting to \(peripheral.identifier.uuidString)...")
        centralManager?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit("connected; discovering services...")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        // Hard cap on the whole session from the moment we are connected.
        queue.asyncAfter(deadline: .now() + .seconds(Int(listenSeconds))) {
            self.emit("listen window elapsed.")
            self.finishWithSummary()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(error: BLEClientError.connectionFailed(error?.localizedDescription ?? "unknown error"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !didFinish, let error {
            finish(error: BLEClientError.connectionFailed(error.localizedDescription))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finish(error: BLEClientError.serviceDiscoveryFailed(error.localizedDescription))
            return
        }
        discoveredServices = peripheral.services ?? []
        emit("services: \(discoveredServices.map { $0.uuid.uuidString }.joined(separator: ", "))")
        guard !discoveredServices.isEmpty else {
            startStepsIfNeeded()
            return
        }
        pendingCharacteristicServiceUUIDs = Set(discoveredServices.map { $0.uuid.uuidString })
        for service in discoveredServices {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            finish(error: BLEClientError.characteristicDiscoveryFailed(error.localizedDescription))
            return
        }
        characteristicsByService[service.uuid.uuidString] = service.characteristics ?? []
        pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)
        guard pendingCharacteristicServiceUUIDs.isEmpty else { return }
        enableNotificationsAndReads(on: peripheral)
    }

    private func enableNotificationsAndReads(on peripheral: CBPeripheral) {
        let allCharacteristics = discoveredServices.flatMap { characteristicsByService[$0.uuid.uuidString] ?? [] }
        let notifyCharacteristics = allCharacteristics.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        let readCharacteristics = allCharacteristics.filter { $0.properties.contains(.read) }

        pendingNotifyEnables = notifyCharacteristics.count
        if notifyCharacteristics.isEmpty {
            emit("no notify/indicate characteristics to subscribe to.")
        }
        for characteristic in notifyCharacteristics {
            emit("subscribing to \(characteristic.uuid.uuidString)...")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        for characteristic in readCharacteristics {
            emit("reading \(characteristic.uuid.uuidString)...")
            peripheral.readValue(for: characteristic)
        }
        if notifyCharacteristics.isEmpty {
            startStepsIfNeeded()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emit("subscribe FAILED \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else if characteristic.isNotifying {
            subscribed.append(characteristic.uuid.uuidString)
            emit("subscribed \(characteristic.uuid.uuidString)")
        }
        pendingNotifyEnables = max(0, pendingNotifyEnables - 1)
        if pendingNotifyEnables == 0 {
            startStepsIfNeeded()
        }
    }

    private func startStepsIfNeeded() {
        guard !didStartSteps else { return }
        didStartSteps = true
        guard !steps.isEmpty else {
            emit("no writes queued; listening for unsolicited notifications.")
            return
        }
        // Let the module settle into transparent mode after the CCCD writes.
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) {
            self.runStep(0)
        }
    }

    private func runStep(_ index: Int) {
        guard index < steps.count else {
            if finishAfterSteps {
                queue.asyncAfter(deadline: .now() + .milliseconds(2000)) {
                    self.emit("all writes done.")
                    self.finishWithSummary()
                }
            }
            return
        }
        let step = steps[index]
        currentStepLabel = step.label
        let didWrite = performWrite(step)
        let dwell = didWrite ? step.dwellMilliseconds : 150
        queue.asyncAfter(deadline: .now() + .milliseconds(max(0, dwell))) {
            self.runStep(index + 1)
        }
    }

    @discardableResult
    private func performWrite(_ step: BLEWriteStep) -> Bool {
        guard let peripheral else { return false }
        let writable = discoveredServices
            .flatMap { characteristicsByService[$0.uuid.uuidString] ?? [] }
            .filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }

        let characteristic: CBCharacteristic?
        if let uuid = step.characteristicUUID {
            characteristic = writable.first { $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }
        } else {
            let preferred = [
                CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID,
                CoreBluetoothTimeboxClient.transparentUARTTXCharacteristicUUID
            ]
            characteristic = writable.first { candidate in
                preferred.contains { candidate.uuid.uuidString.caseInsensitiveCompare($0) == .orderedSame }
            } ?? writable.first
        }

        guard let characteristic else {
            emit("skip [\(step.label)]: characteristic not present or not writable")
            return false
        }

        let type: CBCharacteristicWriteType
        switch step.writeModePreference {
        case .withResponse:
            guard characteristic.properties.contains(.write) else {
                emit("skip [\(step.label)]: \(short(characteristic)) has no write-with-response")
                return false
            }
            type = .withResponse
        case .withoutResponse:
            guard characteristic.properties.contains(.writeWithoutResponse) else {
                emit("skip [\(step.label)]: \(short(characteristic)) has no write-without-response")
                return false
            }
            type = .withoutResponse
        case .automatic:
            if characteristic.properties.contains(.writeWithoutResponse) {
                type = .withoutResponse
            } else if characteristic.properties.contains(.write) {
                type = .withResponse
            } else {
                emit("skip [\(step.label)]: not writable")
                return false
            }
        }

        writesAttempted += 1
        emit(">>> WRITE [\(step.label)] -> \(characteristic.uuid.uuidString) (\(type == .withResponse ? "withResponse" : "withoutResponse")) \(step.data.count)B: \(HexDumpLine.hex(step.data)) — WATCH THE PANEL")
        peripheral.writeValue(step.data, for: characteristic, type: type)
        return true
    }

    private func short(_ characteristic: CBCharacteristic) -> String {
        String(characteristic.uuid.uuidString.prefix(13))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emit("write error \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            emit("write ack \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emit("value error \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        if characteristic.isNotifying {
            notificationCount += 1
            emit("NOTIFY \(characteristic.uuid.uuidString) [after: \(currentStepLabel)]: \(HexDumpLine.hex(data))  | \(HexDumpLine.ascii(data))")
        } else {
            readCount += 1
            emit("READ   \(characteristic.uuid.uuidString): \(HexDumpLine.hex(data))  | \(HexDumpLine.ascii(data))")
        }
    }

    private func finishWithSummary() {
        guard let peripheral else {
            finish(error: BLEClientError.connectionFailed("peripheral disappeared"))
            return
        }
        finish(result: BLEListenSummary(
            peripheralID: peripheral.identifier,
            name: peripheral.name ?? "(unnamed)",
            subscribedCharacteristics: subscribed,
            notificationCount: notificationCount,
            readCount: readCount,
            writesAttempted: writesAttempted
        ))
    }

    private func finish(result: BLEListenSummary) {
        guard !didFinish else { return }
        didFinish = true
        centralManager?.stopScan()
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private func finish(error: Error) {
        guard !didFinish else { return }
        didFinish = true
        centralManager?.stopScan()
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }
}

private enum HexDumpLine {
    static func hex(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func ascii(_ data: Data) -> String {
        String(data.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}
#endif
