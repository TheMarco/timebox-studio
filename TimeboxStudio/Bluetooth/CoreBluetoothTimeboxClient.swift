import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public struct BLECharacteristicSnapshot: Equatable, Sendable {
    public let serviceUUID: String
    public let uuid: String
    public let properties: [String]
    public let canRead: Bool
    public let canWriteWithResponse: Bool
    public let canWriteWithoutResponse: Bool
    public let canNotify: Bool

    public init(
        serviceUUID: String,
        uuid: String,
        properties: [String],
        canRead: Bool,
        canWriteWithResponse: Bool,
        canWriteWithoutResponse: Bool,
        canNotify: Bool
    ) {
        self.serviceUUID = serviceUUID
        self.uuid = uuid
        self.properties = properties
        self.canRead = canRead
        self.canWriteWithResponse = canWriteWithResponse
        self.canWriteWithoutResponse = canWriteWithoutResponse
        self.canNotify = canNotify
    }
}

public struct BLEServiceSnapshot: Equatable, Sendable {
    public let uuid: String
    public let isPrimary: Bool
    public let characteristics: [BLECharacteristicSnapshot]

    public init(uuid: String, isPrimary: Bool, characteristics: [BLECharacteristicSnapshot]) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

public struct BLEPeripheralInspection: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let requestedServiceUUID: String?
    public let usedAllServicesFallback: Bool
    public let services: [BLEServiceSnapshot]

    public init(
        id: UUID,
        name: String,
        requestedServiceUUID: String?,
        usedAllServicesFallback: Bool,
        services: [BLEServiceSnapshot]
    ) {
        self.id = id
        self.name = name
        self.requestedServiceUUID = requestedServiceUUID
        self.usedAllServicesFallback = usedAllServicesFallback
        self.services = services
    }
}

public struct BLEWriteResult: Equatable, Sendable {
    public let peripheralID: UUID
    public let serviceUUID: String
    public let characteristicUUID: String
    public let writeType: String
    public let byteCount: Int

    public init(
        peripheralID: UUID,
        serviceUUID: String,
        characteristicUUID: String,
        writeType: String,
        byteCount: Int
    ) {
        self.peripheralID = peripheralID
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.writeType = writeType
        self.byteCount = byteCount
    }
}

public enum BLEWriteModePreference: String, Equatable, Sendable {
    case automatic
    case withResponse
    case withoutResponse
}

public enum BLEClientError: LocalizedError, Equatable {
    case missingTarget
    case peripheralNotFound(String)
    case connectionFailed(String)
    case serviceDiscoveryFailed(String)
    case characteristicDiscoveryFailed(String)
    case characteristicNotFound(String)
    case noWritableCharacteristic
    case unsupportedWriteMode(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingTarget:
            return "Missing BLE target. Use --uuid or --name."
        case .peripheralNotFound(let target):
            return "Could not find BLE peripheral \(target). Make sure the Timebox is on and advertising."
        case .connectionFailed(let message):
            return "BLE connection failed: \(message)."
        case .serviceDiscoveryFailed(let message):
            return "BLE service discovery failed: \(message)."
        case .characteristicDiscoveryFailed(let message):
            return "BLE characteristic discovery failed: \(message)."
        case .characteristicNotFound(let uuid):
            return "BLE characteristic \(uuid) was not found."
        case .noWritableCharacteristic:
            return "No writable BLE characteristic was found."
        case .unsupportedWriteMode(let message):
            return "BLE characteristic does not support requested write mode: \(message)."
        case .writeFailed(let message):
            return "BLE write failed: \(message)."
        }
    }
}

public enum CoreBluetoothTimeboxClient {
    public static let transparentUARTServiceUUID = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
    public static let transparentUARTTXCharacteristicUUID = "49535343-1E4D-4BD9-BA61-23C647249616"
    public static let transparentUARTRXCharacteristicUUID = "49535343-8841-43F4-A8D4-ECBE34729BB3"

    public static func inspect(
        identifier: UUID?,
        name: String?,
        serviceUUID: String? = nil,
        scanSeconds: UInt8 = 12
    ) async throws -> BLEPeripheralInspection {
        #if canImport(CoreBluetooth)
        let session = BLEClientSession(
            target: BLETarget(identifier: identifier, name: name, serviceUUID: serviceUUID),
            operation: .inspect,
            scanSeconds: scanSeconds
        )
        switch try await session.run() {
        case .inspection(let inspection):
            return inspection
        case .write:
            throw BLEClientError.serviceDiscoveryFailed("unexpected write result")
        }
        #else
        throw BLEScanError.unavailable
        #endif
    }

    public static func write(
        data: Data,
        identifier: UUID?,
        name: String?,
        serviceUUID: String? = nil,
        characteristicUUID: String? = nil,
        writeModePreference: BLEWriteModePreference = .automatic,
        scanSeconds: UInt8 = 12,
        holdMilliseconds: Int = 1500
    ) async throws -> BLEWriteResult {
        #if canImport(CoreBluetooth)
        let session = BLEClientSession(
            target: BLETarget(identifier: identifier, name: name, serviceUUID: serviceUUID),
            operation: .write(
                data: data,
                characteristicUUID: characteristicUUID,
                writeModePreference: writeModePreference
            ),
            scanSeconds: scanSeconds,
            holdMilliseconds: holdMilliseconds
        )
        switch try await session.run() {
        case .inspection:
            throw BLEClientError.writeFailed("unexpected inspection result")
        case .write(let result):
            return result
        }
        #else
        throw BLEScanError.unavailable
        #endif
    }
}

#if canImport(CoreBluetooth)
private struct BLETarget {
    let identifier: UUID?
    let name: String?
    let serviceUUID: String?

    var description: String {
        if let identifier {
            return identifier.uuidString
        }
        if let name {
            return name
        }
        if let serviceUUID {
            return serviceUUID
        }
        return "(unspecified)"
    }

    var serviceCBUUID: CBUUID? {
        serviceUUID.map(CBUUID.init(string:))
    }

    func matches(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
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
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
            return advertisedServices?.contains(serviceCBUUID) == true
        }

        return false
    }
}

private enum BLEOperation {
    case inspect
    case write(data: Data, characteristicUUID: String?, writeModePreference: BLEWriteModePreference)
}

private enum BLEOperationResult {
    case inspection(BLEPeripheralInspection)
    case write(BLEWriteResult)
}

private final class BLEClientSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let target: BLETarget
    private let operation: BLEOperation
    private let scanSeconds: UInt8
    private let holdMilliseconds: Int
    private let queue = DispatchQueue(label: "dev.timeboxstudio.ble-client")

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var continuation: CheckedContinuation<BLEOperationResult, Error>?
    private var didFinish = false
    private var pendingCharacteristicServiceUUIDs = Set<String>()
    private var discoveredServices: [CBService] = []
    private var discoveredCharacteristics: [String: [CBCharacteristic]] = [:]
    private var pendingWriteCharacteristic: CBCharacteristic?
    private var usedAllServicesFallback = false

    init(target: BLETarget, operation: BLEOperation, scanSeconds: UInt8, holdMilliseconds: Int = 1500) {
        self.target = target
        self.operation = operation
        self.scanSeconds = scanSeconds
        self.holdMilliseconds = holdMilliseconds
        super.init()
    }

    func run() async throws -> BLEOperationResult {
        guard target.identifier != nil || target.name != nil || target.serviceUUID != nil else {
            throw BLEClientError.missingTarget
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + .seconds(Int(self.scanSeconds) + 15)) {
                    self.finish(error: BLEScanError.timedOut(seconds: Double(self.scanSeconds) + 15))
                }
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let identifier = target.identifier,
               let retrieved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
                connect(to: retrieved)
                return
            }

            let services = target.serviceCBUUID.map { [$0] }
            central.scanForPeripherals(
                withServices: services,
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
        guard target.matches(peripheral: peripheral, advertisementData: advertisementData) else {
            return
        }
        central.stopScan()
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        let services = target.serviceCBUUID.map { [$0] }
        peripheral.discoverServices(services)
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
        if discoveredServices.isEmpty, target.serviceCBUUID != nil, !usedAllServicesFallback {
            usedAllServicesFallback = true
            peripheral.discoverServices(nil)
            return
        }

        guard !discoveredServices.isEmpty else {
            completeAfterDiscovery()
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

        discoveredCharacteristics[service.uuid.uuidString] = service.characteristics ?? []
        pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)

        if pendingCharacteristicServiceUUIDs.isEmpty {
            completeAfterDiscovery()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finish(error: BLEClientError.writeFailed(error.localizedDescription))
            return
        }

        guard let pendingWriteCharacteristic else {
            finish(error: BLEClientError.writeFailed("write completed for unexpected characteristic"))
            return
        }

        // The peripheral has ACKed the GATT write, but the Transparent UART
        // bridge still has to clock these bytes over its internal UART to the
        // Timebox MCU. Hold the connection open before tearing it down.
        let result = BLEWriteResult(
            peripheralID: peripheral.identifier,
            serviceUUID: pendingWriteCharacteristic.service?.uuid.uuidString ?? "-",
            characteristicUUID: pendingWriteCharacteristic.uuid.uuidString,
            writeType: "withResponse",
            byteCount: writeByteCount
        )
        queue.asyncAfter(deadline: .now() + .milliseconds(holdMilliseconds)) {
            self.finish(result: .write(result))
        }
    }

    private var writeByteCount = 0

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        centralManager?.connect(peripheral, options: nil)
    }

    private func completeAfterDiscovery() {
        switch operation {
        case .inspect:
            guard let peripheral else {
                finish(error: BLEClientError.connectionFailed("peripheral disappeared"))
                return
            }
            finish(result: .inspection(snapshot(for: peripheral)))
        case let .write(data, characteristicUUID, writeModePreference):
            write(data: data, characteristicUUID: characteristicUUID, writeModePreference: writeModePreference)
        }
    }

    private func write(data: Data, characteristicUUID: String?, writeModePreference: BLEWriteModePreference) {
        guard let peripheral else {
            finish(error: BLEClientError.connectionFailed("peripheral disappeared"))
            return
        }

        let writableCharacteristics = discoveredServices
            .flatMap { service in discoveredCharacteristics[service.uuid.uuidString] ?? [] }
            .filter { characteristic in
                if let characteristicUUID,
                   characteristic.uuid.uuidString.caseInsensitiveCompare(characteristicUUID) != .orderedSame {
                    return false
                }
                return characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
            }

        let shouldRestrictToTargetService = target.serviceUUID != nil && !usedAllServicesFallback
        let preferredCharacteristicUUIDs = [
            CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID,
            CoreBluetoothTimeboxClient.transparentUARTTXCharacteristicUUID
        ]

        guard let characteristic = writableCharacteristics.first(where: { candidate in
            guard characteristicUUID == nil else {
                return false
            }
            return preferredCharacteristicUUIDs.contains {
                candidate.uuid.uuidString.caseInsensitiveCompare($0) == .orderedSame
            }
        }) ?? writableCharacteristics.first(where: {
            !shouldRestrictToTargetService || $0.service?.uuid.uuidString.caseInsensitiveCompare(target.serviceUUID ?? "") == .orderedSame
        }) ?? writableCharacteristics.first else {
            if let characteristicUUID {
                finish(error: BLEClientError.characteristicNotFound(characteristicUUID))
            } else {
                finish(error: BLEClientError.noWritableCharacteristic)
            }
            return
        }

        writeByteCount = data.count
        let writeType: CBCharacteristicWriteType
        switch writeModePreference {
        case .withResponse:
            guard characteristic.properties.contains(.write) else {
                finish(error: BLEClientError.unsupportedWriteMode("\(characteristic.uuid.uuidString) has no write-with-response property"))
                return
            }
            writeType = .withResponse
        case .withoutResponse:
            guard characteristic.properties.contains(.writeWithoutResponse) else {
                finish(error: BLEClientError.unsupportedWriteMode("\(characteristic.uuid.uuidString) has no write-without-response property"))
                return
            }
            writeType = .withoutResponse
        case .automatic:
            if characteristic.uuid.uuidString.caseInsensitiveCompare(CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID) == .orderedSame,
               characteristic.properties.contains(.writeWithoutResponse) {
                writeType = .withoutResponse
            } else if characteristic.properties.contains(.write) {
                writeType = .withResponse
            } else if characteristic.properties.contains(.writeWithoutResponse) {
                writeType = .withoutResponse
            } else {
                finish(error: BLEClientError.noWritableCharacteristic)
                return
            }
        }

        if writeType == .withResponse {
            pendingWriteCharacteristic = characteristic
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            queue.asyncAfter(deadline: .now() + .milliseconds(holdMilliseconds)) {
                self.finish(
                    result: .write(
                        BLEWriteResult(
                            peripheralID: peripheral.identifier,
                            serviceUUID: characteristic.service?.uuid.uuidString ?? "-",
                            characteristicUUID: characteristic.uuid.uuidString,
                            writeType: "withoutResponse",
                            byteCount: data.count
                        )
                    )
                )
            }
        }
    }

    private func snapshot(for peripheral: CBPeripheral) -> BLEPeripheralInspection {
        let serviceSnapshots = discoveredServices.map { service in
            let characteristicSnapshots = (discoveredCharacteristics[service.uuid.uuidString] ?? []).map {
                BLECharacteristicSnapshot(
                    serviceUUID: service.uuid.uuidString,
                    uuid: $0.uuid.uuidString,
                    properties: propertyStrings($0.properties),
                    canRead: $0.properties.contains(.read),
                    canWriteWithResponse: $0.properties.contains(.write),
                    canWriteWithoutResponse: $0.properties.contains(.writeWithoutResponse),
                    canNotify: $0.properties.contains(.notify) || $0.properties.contains(.indicate)
                )
            }
            return BLEServiceSnapshot(
                uuid: service.uuid.uuidString,
                isPrimary: service.isPrimary,
                characteristics: characteristicSnapshots
            )
        }

        return BLEPeripheralInspection(
            id: peripheral.identifier,
            name: peripheral.name ?? "(unnamed)",
            requestedServiceUUID: target.serviceUUID,
            usedAllServicesFallback: usedAllServicesFallback,
            services: serviceSnapshots
        )
    }

    private func propertyStrings(_ properties: CBCharacteristicProperties) -> [String] {
        var values: [String] = []
        if properties.contains(.broadcast) { values.append("broadcast") }
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { values.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { values.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { values.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { values.append("indicateEncryptionRequired") }
        return values
    }

    private func finish(result: BLEOperationResult) {
        guard !didFinish else {
            return
        }
        didFinish = true
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private func finish(error: Error) {
        guard !didFinish else {
            return
        }
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
#endif
