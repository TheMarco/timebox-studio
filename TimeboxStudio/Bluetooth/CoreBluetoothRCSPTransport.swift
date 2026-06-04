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

    public var onConnectionChange: ((Bool) -> Void)?
    private var autoReconnect = false         // we've connected once; keep the link alive
    private var lastIdentifier: UUID?         // remembered peripheral, for retrieve-on-reconnect
    private var reconnectPending = false

    // Liveness: the device ACKs/heartbeats on its notify channel. Track in/out timing so a
    // silently-wedged link (write-without-response gives no error) can be detected and reset.
    private var lastInbound = Date.distantPast
    private var lastOutbound = Date.distantPast
    private var sawInbound = false
    private var watchdog: DispatchSourceTimer?

    private var pendingPower: CheckedContinuation<Void, Error>?
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var writeQueue: [(Data, CheckedContinuation<Void, Error>)] = []
    private var activeCont: CheckedContinuation<Void, Error>?
    private var writeChunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var pumpScheduled = false
    private var writeID = 0
    private let writeTimeout: TimeInterval = 3   // a single packet should never take this long

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
        autoReconnect = false               // explicit disconnect — don't try to come back
        stopWatchdog()
        central.stopScan()
        writeChunks.removeAll()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxChar = nil
        finishWrite(.failure(TimeboxTransportError.notConnected))
    }

    public func write(_ data: Data) async throws {
        guard peripheral != nil, rxChar != nil else { throw TimeboxTransportError.notConnected }
        seq = seq &+ 1
        let rcsp = Self.wrapAsRCSP(sppFrame: data, seq: seq)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.append((rcsp, cont))
            startNextWrite()
        }
    }

    /// Writes are serialized: one runs at a time, the rest queue. This stops a send from a
    /// background cover refresh (or any caller) from clobbering an in-flight write's
    /// continuation — which would hang the render loop forever.
    private func startNextWrite() {
        guard activeCont == nil, !writeQueue.isEmpty else { return }
        guard let peripheral, let rx = rxChar else {
            let pending = writeQueue; writeQueue.removeAll()
            pending.forEach { $0.1.resume(throwing: TimeboxTransportError.notConnected) }
            return
        }
        let (rcsp, cont) = writeQueue.removeFirst()
        activeCont = cont
        lastOutbound = Date()
        // write-without-response can't error, so a wedged link (or being suspended mid-write
        // when another app grabs the radio) would hang this write — and the whole render loop
        // awaiting it — forever. Bound it: if the packet hasn't completed in time, the link is
        // dead, so fail it (unblocking the loop) and force a reconnect.
        writeID &+= 1
        let id = writeID
        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeout) { [weak self] in
            guard let self, self.activeCont != nil, self.writeID == id else { return }
            self.forceReconnect()
        }
        writeType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var chunks: [Data] = []
        var i = rcsp.startIndex
        while i < rcsp.endIndex {
            let end = rcsp.index(i, offsetBy: mtu, limitedBy: rcsp.endIndex) ?? rcsp.endIndex
            chunks.append(rcsp.subdata(in: i..<end))
            i = end
        }
        writeChunks = chunks
        // Send the whole packet atomically: the poll keeps draining chunks until done, so
        // we never abandon a half-written RCSP packet (which corrupts the device's parser
        // and drops the connection). A real disconnect unblocks us via the delegate.
        pumpWrites()
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
            finishWrite(.failure(TimeboxTransportError.notConnected)); return
        }
        if writeType == .withoutResponse {
            while !writeChunks.isEmpty {
                if !peripheral.canSendWriteWithoutResponse {
                    // `peripheralIsReady` is sometimes never delivered, which would hang
                    // the write (and the whole animation loop) forever. Poll as a fallback.
                    if !pumpScheduled {
                        pumpScheduled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                            self?.pumpScheduled = false
                            self?.pumpWrites()
                        }
                    }
                    return
                }
                peripheral.writeValue(writeChunks.removeFirst(), for: rx, type: .withoutResponse)
            }
            finishWrite(.success(()))
        } else {
            guard !writeChunks.isEmpty else { finishWrite(.success(())); return }
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

    // MARK: - Aggressive reconnect

    /// After an unexpected drop, keep trying to re-establish the link every couple of
    /// seconds until we're back (or `disconnect()` clears `autoReconnect`). Each round
    /// tries the cheapest path first: re-attach if the system still holds the device (it's
    /// also a BT speaker), reconnect a known peripheral (CoreBluetooth makes that
    /// persistent — it fires the moment the device is reachable), then fall back to scanning.
    private func scheduleReconnect(delay: TimeInterval = 0) {
        guard autoReconnect, !reconnectPending else { return }
        reconnectPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconnectPending = false
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard autoReconnect, !isConnected else { return }
        guard central.state == .poweredOn else { return }   // the poweredOn handler re-kicks us

        if let p = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            attach(p)                                        // system still holds it (speaker)
        } else if let id = lastIdentifier,
                  let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(p)                                        // known peripheral — persistent connect
        } else if let p = peripheral {
            attach(p)
        } else {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
        scheduleReconnect(delay: 2.0)                        // ...and keep at it until connected
    }

    private func attach(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    // MARK: - Liveness watchdog

    /// write-without-response reports no delivery error, so a silently-wedged BLE link looks
    /// "connected" forever while frames vanish into the void — the classic "frozen but the app
    /// thinks it's fine" failure. The device ACKs/heartbeats on its notify channel, so if we're
    /// actively sending yet hear nothing back for a few seconds, the link is dead: drop it,
    /// which triggers `didDisconnect` → the reconnect loop, reviving the session.
    private func startWatchdog() {
        stopWatchdog()
        lastInbound = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.checkLiveness() }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkLiveness() {
        guard isConnected, sawInbound, peripheral != nil else { return }
        let now = Date()
        let activelySending = now.timeIntervalSince(lastOutbound) < 3      // we're streaming frames
        let goneQuiet = now.timeIntervalSince(lastInbound) > 5             // ...but it stopped replying
        if activelySending && goneQuiet { forceReconnect() }
    }

    /// Tear down a wedged link so the reconnect loop can revive it: unblock any stuck write
    /// (so the render loop stops awaiting it), flag the drop, and cancel the connection —
    /// which fires `didDisconnect` → `scheduleReconnect()`.
    private func forceReconnect() {
        guard let p = peripheral else { return }
        sawInbound = false
        rxChar = nil                                    // isConnected → false; stop new writes
        finishWrite(.failure(TimeboxTransportError.notConnected))
        onConnectionChange?(false)
        central.cancelPeripheralConnection(p)
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

    /// Finish the active write and start the next queued one.
    private func finishWrite(_ result: Result<Void, Error>) {
        writeChunks.removeAll()
        if let c = activeCont {
            activeCont = nil
            c.resume(with: result)
        }
        startNextWrite()
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
            if autoReconnect, !isConnected { scheduleReconnect() }   // BT toggled back on
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
        seq = 0                              // fresh GATT session — device counts seq from 1 again
        lastIdentifier = peripheral.identifier
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if pendingConnect != nil {
            resumeConnect(.failure(error ?? TimeboxTransportError.notConnected))
        } else if autoReconnect {
            scheduleReconnect(delay: 1.0)    // mid-reconnect failure — keep hammering
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxChar = nil
        stopWatchdog()
        finishWrite(.failure(TimeboxTransportError.notConnected))
        onConnectionChange?(false)
        // Self-healing reconnect loop: re-attach / reconnect / scan every couple of seconds
        // until the device is back. Survives iOS tearing the link down during app transitions.
        if autoReconnect { scheduleReconnect() }
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
            autoReconnect = true
            startWatchdog()
            if pendingConnect != nil {
                resumeConnect(.success(()))   // initial connect
            } else {
                onConnectionChange?(true)     // came back after a drop
            }
        } else {
            resumeConnect(.failure(TimeboxTransportError.noRFCOMMChannel(nameHint)))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finishWrite(.failure(error)); return }
        if writeType == .withResponse { pumpWrites() }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if writeType == .withoutResponse { pumpWrites() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Any notify traffic (command ACK or heartbeat) proves the link is alive.
        sawInbound = true
        lastInbound = Date()
    }
}
#endif
