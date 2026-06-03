import Foundation
import TimeboxUtilities

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public enum BLEScanError: LocalizedError, Equatable {
    case unavailable
    case unsupported
    case unauthorized
    case poweredOff
    case resetting
    case unknownState(String)
    case timedOut(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "CoreBluetooth is unavailable on this system."
        case .unsupported:
            return "Bluetooth LE is unsupported on this Mac."
        case .unauthorized:
            return "Bluetooth LE access is not authorized. Check macOS Privacy & Security settings for Bluetooth permission."
        case .poweredOff:
            return "Bluetooth is powered off."
        case .resetting:
            return "Bluetooth is resetting. Try again in a moment."
        case .unknownState(let state):
            return "Bluetooth LE is not ready. Current state: \(state)."
        case .timedOut(let seconds):
            return "Bluetooth LE scan timed out after \(String(format: "%.1f", seconds)) seconds."
        }
    }
}

public struct BLEPeripheralSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let advertisedName: String?
    public let rssi: Int
    public let isConnectable: Bool?
    public let serviceUUIDs: [String]
    public let solicitedServiceUUIDs: [String]
    public let overflowServiceUUIDs: [String]
    public let manufacturerDataHex: String?
    public let serviceData: [String: String]
    public let txPowerLevel: Int?

    public init(
        id: UUID,
        name: String,
        advertisedName: String?,
        rssi: Int,
        isConnectable: Bool?,
        serviceUUIDs: [String],
        solicitedServiceUUIDs: [String],
        overflowServiceUUIDs: [String],
        manufacturerDataHex: String?,
        serviceData: [String: String],
        txPowerLevel: Int?
    ) {
        self.id = id
        self.name = name
        self.advertisedName = advertisedName
        self.rssi = rssi
        self.isConnectable = isConnectable
        self.serviceUUIDs = serviceUUIDs
        self.solicitedServiceUUIDs = solicitedServiceUUIDs
        self.overflowServiceUUIDs = overflowServiceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
        self.serviceData = serviceData
        self.txPowerLevel = txPowerLevel
    }

    public var isTimeboxCandidate: Bool {
        let fields = [name, advertisedName].compactMap { $0?.lowercased() }
        return fields.contains { $0.contains("timebox") || $0.contains("divoom") }
    }
}

public enum CoreBluetoothDeviceScanner {
    public static func scanNearby(seconds: UInt8 = 12) async throws -> [BLEPeripheralSnapshot] {
        #if canImport(CoreBluetooth)
        let scanner = BLEScannerDelegate()
        return try await scanner.scan(seconds: seconds)
        #else
        throw BLEScanError.unavailable
        #endif
    }
}

#if canImport(CoreBluetooth)
private final class BLEScannerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.timeboxstudio.ble-scan")
    private var centralManager: CBCentralManager?
    private var continuation: CheckedContinuation<[BLEPeripheralSnapshot], Error>?
    private var snapshotsByID: [UUID: BLEPeripheralSnapshot] = [:]
    private var didFinish = false
    private var scanDurationSeconds = 12

    func scan(seconds: UInt8) async throws -> [BLEPeripheralSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.scanDurationSeconds = Int(seconds)
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue)

                self.queue.asyncAfter(deadline: .now() + .seconds(Int(seconds) + 8)) {
                    self.finishIfNeeded(error: BLEScanError.timedOut(seconds: Double(seconds) + 8))
                }
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )

            queue.asyncAfter(deadline: .now() + .seconds(scanDurationSeconds)) {
                self.finishIfNeeded(error: nil)
            }
        case .poweredOff:
            finishIfNeeded(error: BLEScanError.poweredOff)
        case .unsupported:
            finishIfNeeded(error: BLEScanError.unsupported)
        case .unauthorized:
            finishIfNeeded(error: BLEScanError.unauthorized)
        case .resetting:
            finishIfNeeded(error: BLEScanError.resetting)
        case .unknown:
            break
        @unknown default:
            finishIfNeeded(error: BLEScanError.unknownState("\(central.state.rawValue)"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let snapshot = BLEPeripheralSnapshot(
            id: peripheral.identifier,
            name: peripheral.name ?? "(unnamed)",
            advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            rssi: RSSI.intValue,
            isConnectable: advertisementData[CBAdvertisementDataIsConnectable] as? Bool,
            serviceUUIDs: uuidStrings(advertisementData[CBAdvertisementDataServiceUUIDsKey]),
            solicitedServiceUUIDs: uuidStrings(advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey]),
            overflowServiceUUIDs: uuidStrings(advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey]),
            manufacturerDataHex: (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map {
                HexDump.string(from: $0)
            },
            serviceData: serviceDataStrings(advertisementData[CBAdvertisementDataServiceDataKey]),
            txPowerLevel: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        )

        snapshotsByID[peripheral.identifier] = snapshot
    }

    private func finishIfNeeded(error: Error?) {
        guard !didFinish else {
            return
        }
        didFinish = true
        centralManager?.stopScan()

        let snapshots = snapshotsByID.values.sorted { left, right in
            if left.isTimeboxCandidate != right.isTimeboxCandidate {
                return left.isTimeboxCandidate && !right.isTimeboxCandidate
            }
            if left.rssi != right.rssi {
                return left.rssi > right.rssi
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        let continuation = continuation
        self.continuation = nil

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: snapshots)
        }
    }

    private func uuidStrings(_ value: Any?) -> [String] {
        guard let uuids = value as? [CBUUID] else {
            return []
        }
        return uuids.map(\.uuidString).sorted()
    }

    private func serviceDataStrings(_ value: Any?) -> [String: String] {
        guard let serviceData = value as? [CBUUID: Data] else {
            return [:]
        }

        var strings: [String: String] = [:]
        for (uuid, data) in serviceData {
            strings[uuid.uuidString] = HexDump.string(from: data)
        }
        return strings
    }
}
#endif
