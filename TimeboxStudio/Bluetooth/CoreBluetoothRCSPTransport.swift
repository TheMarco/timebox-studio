import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth
import TimeboxKit

/// BLE transport for the Timebox Evo (iOS, and usable on macOS) using the JieLi RCSP
/// protocol the device's official iOS app speaks.
///
/// `TimeboxClient` hands every command down as a fully-framed Classic-SPP packet
/// (`01 LEN payload CRC 02`). Over BLE the device executes those same SPP command
/// bytes when delivered through its reliable `01` command channel, wrapped in RCSP:
///
///     FE EF AA 55 | LEN(LE16) | 01 <seq> 00 00 00 <SPP payload> | SUM16(LEN+body)(LE16)
///
/// So this transport simply strips the SPP envelope, re-wraps the payload, and writes
/// it (chunked to the negotiated MTU) to the device's RX characteristic. Discovery,
/// brightness, color, and arbitrary 16x16 images all work through the unchanged
/// `TimeboxClient` API — see `timebox-ios-ble-rcsp-protocol` notes.
public final class CoreBluetoothRCSPTransport: NSObject, TimeboxTransport, @unchecked Sendable {
    // Transparent-UART service + characteristics the device exposes.
    private let serviceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    private let rxUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
    private let txUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
    private let connectTimeout: TimeInterval = 15

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var nameHint = "timebox"
    private var seq: UInt8 = 0

    private var pendingPower: CheckedContinuation<Void, Error>?
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var writeChunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withoutResponse

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public var isConnected: Bool { peripheral?.state == .connected && rxChar != nil }

    // MARK: - TimeboxTransport

    public func connect(to device: TimeboxDevice) async throws {
        seq = 0
        nameHint = device.name.isEmpty ? "timebox" : device.name
        try await ensurePoweredOn()

        // The Timebox is also a BT speaker, so the system often already holds it
        // connected (and it then stops advertising) — attach directly if so.
        if let already = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            try await openPeripheral(already)
        } else {
            try await withConnectContinuation {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }

    public func disconnect() {
        central.stopScan()
        writeChunks.removeAll()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxChar = nil
        resumeWrite(.failure(TimeboxTransportError.notConnected))
    }

    public func write(_ data: Data) async throws {
        guard let peripheral, let rx = rxChar else { throw TimeboxTransportError.notConnected }
        seq = seq &+ 1
        let rcsp = Self.wrapAsRCSP(sppFrame: data, seq: seq)
        writeType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var chunks: [Data] = []
        var i = rcsp.startIndex
        while i < rcsp.endIndex {
            let end = rcsp.index(i, offsetBy: mtu, limitedBy: rcsp.endIndex) ?? rcsp.endIndex
            chunks.append(rcsp.subdata(in: i..<end))
            i = end
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingWrite = cont
            writeChunks = chunks
            pumpWrites()
        }
    }

    // MARK: - RCSP framing

    /// Strip the Classic-SPP envelope (`01 LEN payload CRC 02`) and re-wrap the payload
    /// for the device's BLE `01` command channel.
    static func wrapAsRCSP(sppFrame: Data, seq: UInt8) -> Data {
        let payload: Data
        if sppFrame.count > 6, sppFrame.first == 0x01 {
            let lo = sppFrame.index(sppFrame.startIndex, offsetBy: 3)
            let hi = sppFrame.index(sppFrame.endIndex, offsetBy: -3)
            payload = sppFrame.subdata(in: lo..<hi)
        } else {
            payload = sppFrame
        }
        var body = Data([0x01, seq, 0x00, 0x00, 0x00])
        body.append(payload)
        let len = body.count + 2
        let lenLo = UInt8(len & 0xFF), lenHi = UInt8((len >> 8) & 0xFF)
        var sum = Int(lenLo) + Int(lenHi)
        for b in body { sum = (sum + Int(b)) & 0xFFFF }
        var out = Data([0xFE, 0xEF, 0xAA, 0x55, lenLo, lenHi])
        out.append(body)
        out.append(UInt8(sum & 0xFF))
        out.append(UInt8((sum >> 8) & 0xFF))
        return out
    }

    // MARK: - Write pump (honors BLE back-pressure)

    private func pumpWrites() {
        guard let peripheral, let rx = rxChar else {
            resumeWrite(.failure(TimeboxTransportError.notConnected)); return
        }
        if writeType == .withoutResponse {
            while !writeChunks.isEmpty {
                if !peripheral.canSendWriteWithoutResponse { return } // resumed by peripheralIsReady
                peripheral.writeValue(writeChunks.removeFirst(), for: rx, type: .withoutResponse)
            }
            resumeWrite(.success(()))
        } else {
            guard !writeChunks.isEmpty else { resumeWrite(.success(())); return }
            peripheral.writeValue(writeChunks.removeFirst(), for: rx, type: .withResponse)
        }
    }

    // MARK: - Continuation helpers

    private func ensurePoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unsupported || central.state == .unauthorized {
            throw TimeboxTransportError.bluetoothUnavailable
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingPower = cont
        }
    }

    private func openPeripheral(_ p: CBPeripheral) async throws {
        try await withConnectContinuation {
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
        }
    }

    private func withConnectContinuation(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingConnect = cont
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
                guard let self, self.pendingConnect != nil else { return }
                self.central.stopScan()
                self.resumeConnect(.failure(TimeboxTransportError.scanTimedOut(seconds: self.connectTimeout)))
            }
        }
    }

    private func resumeConnect(_ result: Result<Void, Error>) {
        guard let c = pendingConnect else { return }
        pendingConnect = nil
        c.resume(with: result)
    }

    private func resumeWrite(_ result: Result<Void, Error>) {
        guard let c = pendingWrite else { return }
        pendingWrite = nil
        c.resume(with: result)
    }

    private func resumePower(_ result: Result<Void, Error>) {
        guard let c = pendingPower else { return }
        pendingPower = nil
        c.resume(with: result)
    }
}

// MARK: - CoreBluetooth delegates

extension CoreBluetoothRCSPTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            resumePower(.success(()))
        case .unsupported, .unauthorized:
            resumePower(.failure(TimeboxTransportError.bluetoothUnavailable))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard advName.range(of: "timebox", options: .caseInsensitive) != nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resumeConnect(.failure(error ?? TimeboxTransportError.notConnected))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxChar = nil
        resumeWrite(.failure(TimeboxTransportError.notConnected))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            resumeConnect(.failure(TimeboxTransportError.noRFCOMMChannel(nameHint)))
            return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == rxUUID { rxChar = c }
            if c.uuid == txUUID { peripheral.setNotifyValue(true, for: c) }
        }
        if rxChar != nil {
            resumeConnect(.success(()))
        } else {
            resumeConnect(.failure(TimeboxTransportError.noRFCOMMChannel(nameHint)))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { resumeWrite(.failure(error)); return }
        if writeType == .withResponse { pumpWrites() }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if writeType == .withoutResponse { pumpWrites() }
    }
}
#endif
