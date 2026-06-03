import Foundation
import TimeboxBluetooth
import TimeboxKit
import TimeboxUtilities

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [TimeboxDevice] = []
    @Published var selectedDeviceID: TimeboxDevice.ID?
    @Published var useMockTransport = true
    @Published var connectionStatus = "Disconnected"
    @Published var brightnessPercent = 50.0
    @Published var rawHexInput = ""
    @Published var lastPacketHex = ""
    @Published var lastRFCOMMChannelID: UInt8?
    @Published var isBusy = false
    @Published var logEntries: [LogEntry] = []

    private var transport: TimeboxTransport?

    var selectedDevice: TimeboxDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isConnected: Bool {
        transport?.isConnected == true
    }

    func refreshDevices() {
        let scanResult = BluetoothDeviceScanner.scanPairedDevices(includeMock: useMockTransport)
        devices = scanResult.devices
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first(where: { $0.isTimeboxCandidate })?.id ?? devices.first?.id
        }

        let candidateCount = devices.filter(\.isTimeboxCandidate).count
        if scanResult.timedOut {
            log(.error, TimeboxTransportError.scanTimedOut(seconds: scanResult.timeout).localizedDescription)
        } else {
            log(.info, "Detected \(devices.count) paired Bluetooth device(s); \(candidateCount) Timebox candidate(s).")
            if candidateCount == 0, devices.contains(where: \.isTimeboxAudioSide) {
                log(.warning, "Only the Timebox audio-side device is paired. Pair the light/control-side device, usually named Timebox-evo-light, before testing LED control.")
            }
        }
    }

    func connect() {
        guard let selectedDevice else {
            log(.warning, "Connect requested with no selected device.")
            return
        }

        disconnect(silent: true)

        let newTransport: TimeboxTransport = (useMockTransport || selectedDevice.source == .mock)
            ? MockTimeboxTransport()
            : IOBluetoothTimeboxTransport()

        transport = newTransport
        isBusy = true
        connectionStatus = "Connecting to \(selectedDevice.name)..."
        lastRFCOMMChannelID = nil
        log(.info, "Connecting to \(selectedDevice.name) at \(selectedDevice.address) using \(selectedDevice.source.rawValue) transport.")

        Task {
            do {
                try await newTransport.connect(to: selectedDevice)
                isBusy = false
                lastRFCOMMChannelID = (newTransport as? TimeboxTransportDiagnostics)?.lastRFCOMMChannelID
                if let lastRFCOMMChannelID {
                    connectionStatus = "Connected on RFCOMM channel \(lastRFCOMMChannelID)"
                    log(.info, "Connected to \(selectedDevice.name) on RFCOMM channel \(lastRFCOMMChannelID).")
                } else {
                    connectionStatus = "Connected"
                    log(.info, "Connected to \(selectedDevice.name).")
                }
            } catch {
                isBusy = false
                transport = nil
                connectionStatus = "Connection failed"
                log(.error, error.localizedDescription)
            }
        }
    }

    func disconnect(silent: Bool = false) {
        transport?.disconnect()
        transport = nil
        lastRFCOMMChannelID = nil
        connectionStatus = "Disconnected"
        isBusy = false
        if !silent {
            log(.info, "Disconnected.")
        }
    }

    func sendRawHex() {
        guard let transport, transport.isConnected else {
            log(.error, TimeboxTransportError.notConnected.localizedDescription)
            return
        }

        let packet: Data
        do {
            packet = try TimeboxPacketEncoder.encode(.raw(try HexStringParser.data(from: rawHexInput)))
        } catch {
            log(.error, error.localizedDescription)
            return
        }

        lastPacketHex = TimeboxDebugFormatter.packetHex(packet)
        log(.debug, "Outgoing raw packet: \(lastPacketHex)")

        isBusy = true
        Task {
            do {
                try await transport.write(packet)
                isBusy = false
                log(.info, "Sent \(packet.count) raw byte(s).")
            } catch {
                isBusy = false
                log(.error, error.localizedDescription)
            }
        }
    }

    func sendBrightness() {
        guard let transport, transport.isConnected else {
            log(.error, TimeboxTransportError.notConnected.localizedDescription)
            return
        }

        let percent = Int(brightnessPercent.rounded())
        let packet: Data
        do {
            packet = try TimeboxPacketEncoder.encode(.setBrightness(percent))
        } catch {
            log(.error, error.localizedDescription)
            return
        }

        lastPacketHex = TimeboxDebugFormatter.packetHex(packet)
        for line in TimeboxDebugFormatter.commandDebugLines(
            name: "setBrightness",
            parameters: ["brightness: \(percent)%"],
            data: packet
        ) {
            log(.debug, line)
        }

        isBusy = true
        Task {
            do {
                try await transport.write(packet)
                isBusy = false
                log(.info, "Sent brightness command at \(percent)%.")
            } catch {
                isBusy = false
                log(.error, error.localizedDescription)
            }
        }
    }

    func clearDisplayPlaceholder() {
        log(.warning, "Clear-display packet generation is intentionally not implemented in Phase 1/2. Use Raw Hex Sender to test known-good clear packets from the protocol reference.")
    }

    func clearLogs() {
        logEntries.removeAll()
        log(.info, "Debug log cleared.")
    }

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        logEntries.append(entry)
        print(entry.consoleLine)
    }
}
