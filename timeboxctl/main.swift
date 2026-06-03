import Foundation
import TimeboxBluetooth
import TimeboxKit
import TimeboxUtilities

enum TimeboxCLI {
    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 2
        }

        switch command {
        case "list":
            return listDevices(includeMock: arguments.contains("--mock"))
        case "scan":
            return await scanNearby(arguments: Array(arguments.dropFirst()))
        case "scan-ble":
            return await scanBLE(arguments: Array(arguments.dropFirst()))
        case "inspect-ble":
            return await inspectBLE(arguments: Array(arguments.dropFirst()))
        case "send-ble-hex":
            return await sendBLEHex(arguments: Array(arguments.dropFirst()))
        case "brightness", "brightness-ble":
            return await brightnessBLE(arguments: Array(arguments.dropFirst()))
        case "color", "color-ble":
            return await colorBLE(arguments: Array(arguments.dropFirst()))
        case "listen-ble":
            return await listenBLE(arguments: Array(arguments.dropFirst()))
        case "probe-ble-write":
            return await probeBLEWrite(arguments: Array(arguments.dropFirst()))
        case "inspect":
            return await inspect(arguments: Array(arguments.dropFirst()))
        case "probe-rfcomm":
            return await probeRFCOMM(arguments: Array(arguments.dropFirst()))
        case "connect":
            return await connect(arguments: Array(arguments.dropFirst()))
        case "send-hex":
            return await sendHex(arguments: Array(arguments.dropFirst()))
        default:
            fputs("Unknown command: \(command)\n\n", stderr)
            printUsage()
            return 2
        }
    }

    private static func listDevices(includeMock: Bool) -> Int32 {
        let scanResult = BluetoothDeviceScanner.scanPairedDevices(includeMock: includeMock)
        if scanResult.timedOut {
            fputs("\(TimeboxTransportError.scanTimedOut(seconds: scanResult.timeout).localizedDescription)\n", stderr)
            return 1
        }

        let devices = scanResult.devices
        if devices.isEmpty {
            print("No paired Bluetooth devices found.")
            return 0
        }

        printDevices(devices)

        if devices.contains(where: \.isTimeboxAudioSide) && !devices.contains(where: \.isTimeboxCandidate) {
            print("")
            print("Note: only the Timebox audio-side device is paired. LED control needs the light/control-side device, usually named Timebox-evo-light.")
        }

        return 0
    }

    private static func scanNearby(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            if options.useMock {
                printDevices([.mock])
                return 0
            }

            let seconds = options.seconds ?? 12
            print("Scanning for nearby Bluetooth Classic devices for \(seconds) second(s)...")
            let devices = try await BluetoothDeviceScanner.scanNearbyDevices(
                inquiryLength: seconds,
                timeout: TimeInterval(seconds) + 18
            )

            if devices.isEmpty {
                print("No nearby Bluetooth Classic devices found.")
                return 0
            }

            printDevices(devices)

            if devices.contains(where: \.isTimeboxAudioSide) && !devices.contains(where: \.isTimeboxCandidate) {
                print("")
                print("Note: found the Timebox audio-side device, but not a light/control-side Timebox name.")
            }

            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printDevices(_ devices: [TimeboxDevice]) {
        for device in devices {
            let marker = device.isTimeboxCandidate ? "*" : " "
            print("\(marker) \(device.name)")
            print("    address: \(device.address)")
            print("    paired: \(device.isPaired ? "yes" : "no")")
            print("    connected: \(device.isConnected ? "yes" : "no")")
            print("    source: \(device.source.rawValue)")
        }
    }

    private static func scanBLE(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let seconds = options.seconds ?? 12
            if options.useMock {
                printBLESnapshots([
                    BLEPeripheralSnapshot(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        name: "Mock Timebox-evo-light",
                        advertisedName: "Timebox-evo-light",
                        rssi: -42,
                        isConnectable: true,
                        serviceUUIDs: ["FFE0"],
                        solicitedServiceUUIDs: [],
                        overflowServiceUUIDs: [],
                        manufacturerDataHex: "44 49 56 4F 4F 4D",
                        serviceData: [:],
                        txPowerLevel: nil
                    )
                ])
                return 0
            }

            print("Scanning for nearby Bluetooth LE advertisements for \(seconds) second(s)...")
            let snapshots = try await CoreBluetoothDeviceScanner.scanNearby(seconds: seconds)

            if snapshots.isEmpty {
                print("No nearby Bluetooth LE advertisements found.")
                return 0
            }

            printBLESnapshots(snapshots)
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printBLESnapshots(_ snapshots: [BLEPeripheralSnapshot]) {
        for snapshot in snapshots {
            let marker = snapshot.isTimeboxCandidate ? "*" : " "
            print("\(marker) \(snapshot.name)")
            print("    uuid: \(snapshot.id.uuidString)")
            print("    advertised name: \(snapshot.advertisedName ?? "-")")
            print("    rssi: \(snapshot.rssi)")
            print("    connectable: \(snapshot.isConnectable.map { $0 ? "yes" : "no" } ?? "-")")
            print("    services: \(snapshot.serviceUUIDs.isEmpty ? "-" : snapshot.serviceUUIDs.joined(separator: ", "))")
            print("    solicited services: \(snapshot.solicitedServiceUUIDs.isEmpty ? "-" : snapshot.solicitedServiceUUIDs.joined(separator: ", "))")
            print("    overflow services: \(snapshot.overflowServiceUUIDs.isEmpty ? "-" : snapshot.overflowServiceUUIDs.joined(separator: ", "))")
            print("    manufacturer data: \(snapshot.manufacturerDataHex ?? "-")")
            if snapshot.serviceData.isEmpty {
                print("    service data: -")
            } else {
                print("    service data:")
                for key in snapshot.serviceData.keys.sorted() {
                    print("      \(key): \(snapshot.serviceData[key] ?? "")")
                }
            }
            print("")
        }
    }

    private static func inspectBLE(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let inspection = try await CoreBluetoothTimeboxClient.inspect(
                identifier: options.uuid,
                name: options.name,
                serviceUUID: options.serviceUUID,
                scanSeconds: options.seconds ?? 12
            )
            printBLEInspection(inspection)
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func sendBLEHex(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: true)
            let packet = try HexStringParser.data(from: options.hexInput)
            let result = try await CoreBluetoothTimeboxClient.write(
                data: packet,
                identifier: options.uuid,
                name: options.name,
                serviceUUID: options.serviceUUID,
                characteristicUUID: options.characteristicUUID,
                writeModePreference: options.writeModePreference,
                scanSeconds: options.seconds ?? 12
            )

            print("Wrote \(result.byteCount) byte(s) over BLE.")
            print("    peripheral: \(result.peripheralID.uuidString)")
            print("    service: \(result.serviceUUID)")
            print("    characteristic: \(result.characteristicUUID)")
            print("    write type: \(result.writeType)")
            print("    hex: \(HexDump.string(from: packet))")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func brightnessBLE(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let percent = try parseBrightnessPercent(options.hexInput)
            let packet = try TimeboxPacketEncoder.encode(.setBrightness(percent))

            for line in TimeboxDebugFormatter.commandDebugLines(
                name: "setBrightness",
                parameters: ["brightness: \(percent)%"],
                data: packet
            ) {
                print(line)
            }

            if options.useMock {
                print("Mock mode: not writing to hardware.")
                return 0
            }

            let result = try await CoreBluetoothTimeboxClient.write(
                data: packet,
                identifier: options.uuid,
                name: options.name ?? "Timebox-Evo-light",
                serviceUUID: options.serviceUUID,
                characteristicUUID: options.characteristicUUID ?? CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID,
                writeModePreference: options.writeModePreference,
                scanSeconds: options.seconds ?? 12
            )

            print("Wrote \(result.byteCount) byte(s) over BLE.")
            print("    peripheral: \(result.peripheralID.uuidString)")
            print("    service: \(result.serviceUUID)")
            print("    characteristic: \(result.characteristicUUID)")
            print("    write type: \(result.writeType)")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func colorBLE(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: true)
            let color = try parseColor(options.hexInput)
            let percent = options.brightness ?? 100
            let packet = try TimeboxPacketEncoder.encode(
                .lightningPlainColor(color: color, brightnessPercent: percent)
            )

            for line in TimeboxDebugFormatter.commandDebugLines(
                name: "lightningPlainColor",
                parameters: [
                    "color: #\(String(format: "%02X%02X%02X", color.red, color.green, color.blue))",
                    "brightness: \(percent)%"
                ],
                data: packet
            ) {
                print(line)
            }

            if options.useMock {
                print("Mock mode: not writing to hardware.")
                return 0
            }

            let result = try await CoreBluetoothTimeboxClient.write(
                data: packet,
                identifier: options.uuid,
                name: options.name ?? "Timebox-Evo-light",
                serviceUUID: options.serviceUUID,
                characteristicUUID: options.characteristicUUID ?? CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID,
                writeModePreference: options.writeModePreference,
                scanSeconds: options.seconds ?? 12,
                holdMilliseconds: options.holdMilliseconds ?? 2000
            )

            print("Wrote \(result.byteCount) byte(s) over BLE.")
            print("    peripheral: \(result.peripheralID.uuidString)")
            print("    service: \(result.serviceUUID)")
            print("    characteristic: \(result.characteristicUUID)")
            print("    write type: \(result.writeType)")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func listenBLE(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let seconds = options.seconds ?? 20

            // Optional packet to send once notifications are enabled.
            var sendPacket: Data?
            let trimmedHex = options.hexInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHex.isEmpty {
                sendPacket = try HexStringParser.data(from: trimmedHex)
            } else if options.requestSettings {
                // PROTOCOL.md request-settings readback: payload 46 -> 01 03 00 46 49 00 02.
                sendPacket = try TimeboxPacketEncoder.encodePayload(Data([0x46]))
            }

            if let sendPacket {
                print("Will send after subscribing: \(HexDump.string(from: sendPacket))")
            }
            print("Listening on BLE for \(seconds) second(s)...")

            let summary = try await CoreBluetoothTimeboxListener.listen(
                identifier: options.uuid,
                name: options.name,
                serviceUUID: options.serviceUUID,
                listenSeconds: seconds,
                send: sendPacket,
                writeModePreference: options.writeModePreference,
                onEvent: { line in print(line) }
            )

            print("")
            printListenSummary(summary)
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func probeBLEWrite(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)

            // Packet to probe with: trailing hex, or --request-settings, or a
            // bright-red full-screen fill by default (the most visible test).
            let packet: Data
            let trimmedHex = options.hexInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHex.isEmpty {
                packet = try HexStringParser.data(from: trimmedHex)
            } else if options.requestSettings {
                packet = try TimeboxPacketEncoder.encodePayload(Data([0x46]))
            } else {
                packet = try TimeboxPacketEncoder.encode(
                    .lightningPlainColor(color: PixelRGB(red: 0xFF, green: 0x00, blue: 0x00), brightnessPercent: 100)
                )
            }

            let candidates = [
                CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID,   // 8841 (standard RX)
                CoreBluetoothTimeboxClient.transparentUARTTXCharacteristicUUID,   // 1E4D (standard TX, writable)
                "49535343-ACA3-481C-91EC-D85E28A60318"                            // proprietary write+notify
            ]

            print("Probing writable characteristics with: \(HexDump.string(from: packet))")
            print("Each candidate is written with and without response; watch the panel during each WRITE banner.")
            print("")

            let summary = try await CoreBluetoothTimeboxListener.probe(
                identifier: options.uuid,
                name: options.name,
                serviceUUID: options.serviceUUID,
                packet: packet,
                characteristicUUIDs: candidates,
                dwellMilliseconds: options.holdMilliseconds ?? 3000,
                onEvent: { line in print(line) }
            )

            print("")
            printListenSummary(summary)
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printListenSummary(_ summary: BLEListenSummary) {
        print("Summary:")
        print("    peripheral: \(summary.peripheralID.uuidString) (\(summary.name))")
        print("    subscribed: \(summary.subscribedCharacteristics.isEmpty ? "none" : summary.subscribedCharacteristics.joined(separator: ", "))")
        print("    notifications received: \(summary.notificationCount)")
        print("    reads received: \(summary.readCount)")
        print("    writes attempted: \(summary.writesAttempted)")
        if summary.notificationCount == 0 && summary.writesAttempted > 0 {
            print("    note: device sent nothing back after any write. If the panel also never changed, the BLE Transparent UART pipe is likely not feeding the Timebox protocol parser; the Classic SPP/RFCOMM path is the next thing to try.")
        }
    }

    private static func printBLEInspection(_ inspection: BLEPeripheralInspection) {
        print("\(inspection.name)")
        print("    uuid: \(inspection.id.uuidString)")
        if let requestedServiceUUID = inspection.requestedServiceUUID {
            print("    requested service: \(requestedServiceUUID)")
            print("    all-services fallback: \(inspection.usedAllServicesFallback ? "yes" : "no")")
        }

        if inspection.services.isEmpty {
            print("    services: none")
            return
        }

        print("    services:")
        for service in inspection.services {
            print("      \(service.uuid) primary: \(service.isPrimary ? "yes" : "no")")
            if service.characteristics.isEmpty {
                print("          characteristics: none")
            } else {
                for characteristic in service.characteristics {
                    print("          characteristic: \(characteristic.uuid)\(bleCharacteristicHint(characteristic.uuid))")
                    print("              properties: \(characteristic.properties.isEmpty ? "-" : characteristic.properties.joined(separator: ", "))")
                    print("              read: \(characteristic.canRead ? "yes" : "no")")
                    print("              write: \(characteristic.canWriteWithResponse ? "yes" : "no")")
                    print("              write without response: \(characteristic.canWriteWithoutResponse ? "yes" : "no")")
                    print("              notify/indicate: \(characteristic.canNotify ? "yes" : "no")")
                }
            }
        }
    }

    private static func bleCharacteristicHint(_ uuid: String) -> String {
        if uuid.caseInsensitiveCompare(CoreBluetoothTimeboxClient.transparentUARTRXCharacteristicUUID) == .orderedSame {
            return " (Transparent UART RX: write target)"
        }
        if uuid.caseInsensitiveCompare(CoreBluetoothTimeboxClient.transparentUARTTXCharacteristicUUID) == .orderedSame {
            return " (Transparent UART TX: notify/readback path)"
        }
        return ""
    }

    private static func connect(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let device = try resolveDevice(name: options.name, address: options.address, useMock: options.useMock)
            let transport: TimeboxTransport = options.useMock || device.source == .mock
                ? MockTimeboxTransport()
                : IOBluetoothTimeboxTransport()

            let channelDescription = options.channel.map { " on RFCOMM channel \($0)" } ?? ""
            print("Connecting to \(device.name) (\(device.address))\(channelDescription)...")
            try await connect(transport, to: device, channelID: options.channel)

            if let diagnostics = transport as? TimeboxTransportDiagnostics,
               let channelID = diagnostics.lastRFCOMMChannelID {
                print("Connected on RFCOMM channel \(channelID).")
            } else {
                print("Connected.")
            }
            transport.disconnect()
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func sendHex(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: true)
            let device = try resolveDevice(name: options.name, address: options.address, useMock: options.useMock)
            let packet = try TimeboxPacketEncoder.encode(.raw(HexStringParser.data(from: options.hexInput)))
            let transport: TimeboxTransport = options.useMock || device.source == .mock
                ? MockTimeboxTransport()
                : IOBluetoothTimeboxTransport()

            let channelDescription = options.channel.map { " on RFCOMM channel \($0)" } ?? ""
            print("Connecting to \(device.name) (\(device.address))\(channelDescription)...")
            try await connect(transport, to: device, channelID: options.channel)

            if let diagnostics = transport as? TimeboxTransportDiagnostics,
               let channelID = diagnostics.lastRFCOMMChannelID {
                print("RFCOMM channel: \(channelID)")
            }

            print("Sending \(packet.count) byte(s): \(HexDump.string(from: packet))")
            try await transport.write(packet)
            print("Sent.")
            transport.disconnect()
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func probeRFCOMM(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let channels = options.channels.isEmpty ? Array(UInt8(1)...UInt8(8)) : options.channels
            let device = try resolveDevice(name: options.name, address: options.address, useMock: options.useMock)

            print("Probing \(device.name) (\(device.address))")
            print("Channels: \(channels.map(String.init).joined(separator: ", "))")

            var successCount = 0
            for channelID in channels {
                let transport: TimeboxTransport = options.useMock || device.source == .mock
                    ? MockTimeboxTransport()
                    : IOBluetoothTimeboxTransport()

                do {
                    try await connect(transport, to: device, channelID: channelID)
                    successCount += 1
                    print("  channel \(channelID): open")
                    transport.disconnect()
                } catch {
                    print("  channel \(channelID): \(error.localizedDescription)")
                    transport.disconnect()
                }
            }

            return successCount > 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: - Synchronous Classic (IOBluetooth) command path
    //
    // IOBluetooth RFCOMM callbacks are delivered on the main run loop, so these
    // commands run synchronously on the main thread and pump it, instead of going
    // through the async runtime (which leaves the main run loop unserviced).

    static func runClassicSync(command: String, arguments: [String]) -> Int32 {
        switch command {
        case "send-hex":
            return sendHexSync(arguments: arguments)
        case "connect":
            return connectSync(arguments: arguments)
        case "probe-rfcomm":
            return probeRFCOMMSync(arguments: arguments)
        case "color":
            return colorSPP(arguments: arguments)
        case "brightness":
            return brightnessSPP(arguments: arguments)
        case "image":
            return imageSPP(arguments: arguments)
        case "repl":
            return replSPP(arguments: arguments)
        default:
            return 2
        }
    }

    private static func brightnessSPP(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let percent = try parseBrightnessPercent(options.hexInput)
            let packet = try TimeboxPacketEncoder.encode(.setBrightness(percent))
            for line in TimeboxDebugFormatter.commandDebugLines(
                name: "setBrightness",
                parameters: ["brightness: \(percent)%"],
                data: packet
            ) {
                print(line)
            }
            return sendSPP(packet: packet, options: options)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func colorSPP(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: true)
            let color = try parseColor(options.hexInput)
            let percent = options.brightness ?? 100
            let packet = try TimeboxPacketEncoder.encode(
                .lightningPlainColor(color: color, brightnessPercent: percent)
            )
            for line in TimeboxDebugFormatter.commandDebugLines(
                name: "lightningPlainColor",
                parameters: [
                    "color: #\(String(format: "%02X%02X%02X", color.red, color.green, color.blue))",
                    "brightness: \(percent)%"
                ],
                data: packet
            ) {
                print(line)
            }
            return sendSPP(packet: packet, options: options)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func imageSPP(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let path = options.hexInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw CLIError.missingImagePath }
            let frame = try ImageToPixelFrameConverter.loadPixelFrame(path: path)
            let packet = try TimeboxPacketEncoder.encode(.image(frame))
            print("image: \(path) -> 16x16, packet \(packet.count) byte(s)")
            return sendSPP(packet: packet, options: options)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Sends an already-encoded Timebox packet over Bluetooth Classic SPP/RFCOMM
    /// (the verified control path for the Timebox Evo). Defaults to channel 1.
    /// Holds the connection open after the write so the device can finish parsing
    /// before teardown (the firmware drops commands cut off too soon), and retries
    /// the connect if macOS is momentarily holding the channel.
    private static func sendSPP(packet: Data, options: ParsedOptions) -> Int32 {
        let holdMs = options.holdMilliseconds ?? 500
        let device: TimeboxDevice
        do {
            device = try resolveDevice(name: options.name, address: options.address, useMock: false)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
        let channelDescription = options.channel.map { "RFCOMM channel \($0)" } ?? "auto-resolved SPP channel"

        var lastError: Error?
        for attempt in 1...3 {
            let transport = IOBluetoothTimeboxTransport()
            do {
                print(attempt == 1
                    ? "Connecting to \(device.name) (\(device.address)) on \(channelDescription)..."
                    : "Retry \(attempt)/3...")
                try transport.connectPumpingRunLoop(to: device, channelID: options.channel)
                if let channelID = transport.lastRFCOMMChannelID {
                    print("RFCOMM channel: \(channelID)")
                }
                transport.waitPumpingRunLoop(milliseconds: 150)    // let the device's parser settle after connect
                try transport.writePumpingRunLoop(packet)
                transport.waitPumpingRunLoop(milliseconds: holdMs) // let the device process before teardown
                transport.disconnect()
                print("Sent \(packet.count) byte(s).")
                return 0
            } catch {
                lastError = error
                transport.disconnect()
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        fputs("\((lastError ?? CLIError.missingDeviceSelector("send")).localizedDescription)\n", stderr)
        return 1
    }

    /// Interactive mode: open ONE persistent SPP connection and stream commands
    /// from stdin (color / brightness / hex). This matches the official app's
    /// model (it never reconnects per command) and is far more reliable than the
    /// one-shot connect-write-close path.
    private static func replSPP(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let device = try resolveDevice(name: options.name, address: options.address, useMock: false)
            let transport = IOBluetoothTimeboxTransport()
            let channelDescription = options.channel.map { "RFCOMM channel \($0)" } ?? "auto-resolved SPP channel"
            print("Connecting to \(device.name) (\(device.address)) on \(channelDescription)...")
            try transport.connectPumpingRunLoop(to: device, channelID: options.channel)
            transport.waitPumpingRunLoop(milliseconds: 150)
            if let channelID = transport.lastRFCOMMChannelID {
                print("Connected on RFCOMM channel \(channelID). Persistent connection open.")
            }
            printReplHelp()

            while true {
                print("timebox> ", terminator: "")
                fflush(stdout)
                guard let line = readLine(strippingNewline: true) else { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let lower = trimmed.lowercased()
                if lower == "quit" || lower == "exit" || lower == "q" { break }
                if lower == "help" || lower == "?" { printReplHelp(); continue }
                do {
                    let packet = try parseReplCommand(trimmed)
                    try transport.writePumpingRunLoop(packet)
                    transport.waitPumpingRunLoop(milliseconds: 60)
                    print("  ok (\(packet.count) bytes: \(HexDump.string(from: packet)))")
                } catch {
                    print("  error: \(error.localizedDescription)")
                }
            }

            transport.disconnect()
            print("Disconnected.")
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printReplHelp() {
        print("""
        Persistent SPP connection. Type a command + Enter:
          color RRGGBB [brightness 0-100]   e.g.  color FF0000   |   color 00FF00 40
          brightness 0-100                  e.g.  brightness 25
          image <path>                      e.g.  image test.png   (PNG/JPG -> 16x16)
          hex AA BB CC ...                  raw pre-framed packet
          help | quit
        """)
    }

    private static func parseReplCommand(_ line: String) throws -> Data {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first?.lowercased() {
        case "color":
            guard parts.count >= 2 else { throw CLIError.missingColor }
            let color = try parseColor(parts[1])
            let percent = parts.count >= 3 ? (Int(parts[2]) ?? 100) : 100
            return try TimeboxPacketEncoder.encode(
                .lightningPlainColor(color: color, brightnessPercent: max(0, min(100, percent)))
            )
        case "brightness", "bright":
            guard parts.count >= 2, let percent = Int(parts[1]) else { throw CLIError.missingBrightness }
            return try TimeboxPacketEncoder.encode(.setBrightness(max(0, min(100, percent))))
        case "image", "img":
            guard parts.count >= 2 else { throw CLIError.missingImagePath }
            let frame = try ImageToPixelFrameConverter.loadPixelFrame(path: parts.dropFirst().joined(separator: " "))
            return try TimeboxPacketEncoder.encode(.image(frame))
        case "hex":
            return try TimeboxPacketEncoder.encode(.raw(HexStringParser.data(from: parts.dropFirst().joined(separator: " "))))
        default:
            return try TimeboxPacketEncoder.encode(.raw(HexStringParser.data(from: line)))
        }
    }

    private static func sendHexSync(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: true)
            let device = try resolveDevice(name: options.name, address: options.address, useMock: false)
            let packet = try TimeboxPacketEncoder.encode(.raw(HexStringParser.data(from: options.hexInput)))
            let transport = IOBluetoothTimeboxTransport()

            let channelDescription = options.channel.map { " on RFCOMM channel \($0)" } ?? ""
            print("Connecting to \(device.name) (\(device.address))\(channelDescription)...")
            try transport.connectPumpingRunLoop(to: device, channelID: options.channel)

            if let channelID = transport.lastRFCOMMChannelID {
                print("RFCOMM channel: \(channelID)")
            }
            print("Sending \(packet.count) byte(s): \(HexDump.string(from: packet))")
            try transport.writePumpingRunLoop(packet)
            print("Sent.")
            transport.disconnect()
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func connectSync(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let device = try resolveDevice(name: options.name, address: options.address, useMock: false)
            let channelDescription = options.channel.map { " on RFCOMM channel \($0)" } ?? ""
            print("Connecting to \(device.name) (\(device.address))\(channelDescription)...")
            let transport = IOBluetoothTimeboxTransport()
            try transport.connectPumpingRunLoop(to: device, channelID: options.channel)

            if let channelID = transport.lastRFCOMMChannelID {
                print("Connected on RFCOMM channel \(channelID).")
            } else {
                print("Connected.")
            }
            transport.disconnect()
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func probeRFCOMMSync(arguments: [String]) -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            let channels = options.channels.isEmpty ? Array(UInt8(1)...UInt8(8)) : options.channels
            let device = try resolveDevice(name: options.name, address: options.address, useMock: false)

            print("Probing \(device.name) (\(device.address))")
            print("Channels: \(channels.map(String.init).joined(separator: ", "))")

            var successCount = 0
            for channelID in channels {
                let transport = IOBluetoothTimeboxTransport()
                do {
                    try transport.connectPumpingRunLoop(to: device, channelID: channelID)
                    successCount += 1
                    print("  channel \(channelID): open")
                    transport.disconnect()
                } catch {
                    print("  channel \(channelID): \(error.localizedDescription)")
                    transport.disconnect()
                }
            }

            return successCount > 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func connect(_ transport: TimeboxTransport, to device: TimeboxDevice, channelID: UInt8?) async throws {
        if let channelID, let bluetoothTransport = transport as? IOBluetoothTimeboxTransport {
            try await bluetoothTransport.connect(to: device, channelID: channelID)
        } else {
            try await transport.connect(to: device)
        }
    }

    private static func inspect(arguments: [String]) async -> Int32 {
        do {
            let options = try ParsedOptions(arguments: arguments, requiresHex: false)
            if options.useMock {
                printInspection(
                    BluetoothDeviceInspection(
                        device: .mock,
                        sdpStatus: 0,
                        sdpStatusMessage: "mock",
                        services: [
                            BluetoothServiceInfo(
                                index: 0,
                                name: "Mock RFCOMM service",
                                rfcommChannelID: 1,
                                l2capPSM: nil,
                                serviceRecordHandle: nil,
                                attributeCount: 0
                            )
                        ]
                    )
                )
                return 0
            }

            if let address = options.address {
                printInspection(try await BluetoothDeviceInspector.inspect(address: address))
                return 0
            }

            guard let name = options.name else {
                throw CLIError.missingDeviceSelector("inspect")
            }

            let inspections = try await BluetoothDeviceInspector.inspect(name: name)
            for inspection in inspections {
                printInspection(inspection)
            }
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printInspection(_ inspection: BluetoothDeviceInspection) {
        let device = inspection.device
        print("\(device.name)")
        print("    address: \(device.address)")
        print("    paired: \(device.isPaired ? "yes" : "no")")
        print("    connected: \(device.isConnected ? "yes" : "no")")
        print("    SDP status: \(TimeboxTransportError.formatIOReturn(inspection.sdpStatus)) (\(inspection.sdpStatusMessage))")

        if inspection.services.isEmpty {
            print("    services: none returned")
            return
        }

        print("    services:")
        for service in inspection.services {
            let handle = service.serviceRecordHandle.map { "0x\(String(format: "%08X", $0))" } ?? "-"
            let rfcomm = service.rfcommChannelID.map(String.init) ?? "-"
            let psm = service.l2capPSM.map { "0x\(String(format: "%04X", $0))" } ?? "-"
            print("      [\(service.index)] \(service.name)")
            print("          RFCOMM: \(rfcomm)")
            print("          L2CAP PSM: \(psm)")
            print("          handle: \(handle)")
            print("          attributes: \(service.attributeCount)")
        }
    }

    private static func resolveDevice(name: String?, address: String?, useMock: Bool) throws -> TimeboxDevice {
        if useMock {
            return .mock
        }

        if let address, !address.isEmpty {
            return TimeboxDevice(
                name: "Bluetooth device \(address)",
                address: address,
                isPaired: false,
                isConnected: false,
                source: .bluetooth
            )
        }

        if let device = try BluetoothDeviceScanner.firstTimeboxCandidate(named: name, includeMock: false) {
            return device
        }

        if let name, !name.isEmpty {
            throw TimeboxTransportError.deviceNotFound(name)
        }

        throw TimeboxTransportError.deviceNotFound("first paired device whose name contains Timebox")
    }

    private static func parseColor(_ input: String) throws -> PixelRGB {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.missingColor
        }
        let bytes: [UInt8]
        do {
            bytes = Array(try HexStringParser.data(from: trimmed))
        } catch {
            throw CLIError.invalidColor(trimmed)
        }
        guard bytes.count == 3 else {
            throw CLIError.invalidColor(trimmed)
        }
        return PixelRGB(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    private static func parseBrightnessPercent(_ input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.missingBrightness
        }
        guard let percent = Int(trimmed), (0...100).contains(percent) else {
            throw CLIError.invalidBrightness(trimmed)
        }
        return percent
    }

    private static func printUsage() {
        print(
            """
            Usage:
              timeboxctl list [--mock]
              timeboxctl scan [--seconds 12] [--mock]
              timeboxctl scan-ble [--seconds 12]
              timeboxctl inspect-ble --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" [--service AF30]
              timeboxctl send-ble-hex --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" [--characteristic UUID] [--with-response | --without-response] "AA BB CC"
              timeboxctl brightness 50 --address AA-BB-CC-DD-EE-FF [--channel 1]        (Classic SPP, verified Timebox Evo path)
              timeboxctl color FF0000 --address AA-BB-CC-DD-EE-FF [--channel 1] [--brightness 100]   (Classic SPP)
              timeboxctl image test.png --address AA-BB-CC-DD-EE-FF [--channel 1]    (PNG/JPG -> 16x16 picture on the display)
              timeboxctl repl --address AA-BB-CC-DD-EE-FF [--channel 1]              (interactive: one persistent SPP connection, stream commands)
              timeboxctl brightness 50 --uuid "BE32D255-...-0458D3"                    (BLE; legacy/diagnostic, no visible effect on Evo)
              timeboxctl color FF0000 --uuid "BE32D255-...-0458D3" [--brightness 100]  (BLE; legacy/diagnostic)
              timeboxctl listen-ble --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" [--seconds 20] [--request-settings | "01 03 00 46 49 00 02"] [--with-response | --without-response]
              timeboxctl probe-ble-write --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" [--request-settings | "AA BB CC"] [--hold-ms 3000]
              timeboxctl inspect --name "Timebox-evo-light"
              timeboxctl inspect --address "fa-5e-6f-6e-79-42"
              timeboxctl probe-rfcomm --address "fa-5e-6f-6e-79-42" [--channels "1,2,3,4"]
              timeboxctl connect [--name "Timebox-evo-light" | --address "fa-5e-6f-6e-79-42"] [--channel 1] [--mock]
              timeboxctl send-hex [--name "Timebox-evo-light" | --address "fa-5e-6f-6e-79-42"] [--channel 1] [--mock] "AA BB CC"

            Notes:
              list shows paired macOS Bluetooth devices.
              scan actively searches nearby Bluetooth Classic devices that may not be paired yet.
              scan-ble actively scans Bluetooth LE advertisements and prints UUIDs/service data.
              inspect-ble connects over BLE and discovers services/characteristics.
              send-ble-hex writes raw bytes to a BLE characteristic, auto-selecting a writable one if --characteristic is omitted.
              brightness builds the Timebox Evo brightness packet and writes it over BLE Transparent UART.
              color fills the whole display with one RGB color (lightning channel, plain color) over BLE; a much more visible effect than brightness. --hold-ms keeps the BLE link open after the write so the Transparent UART bridge can flush bytes to the device.
              listen-ble connects, subscribes to every notify characteristic, optionally sends one packet after subscribing (raw hex, or --request-settings), and streams back any value the device reports. This proves whether the BLE pipe actually feeds the Timebox protocol parser.
              probe-ble-write connects once, subscribes, then writes the packet (default: bright-red fill) to each candidate characteristic (8841, 1E4D, ACA3) with and without response, dwelling between writes so you can watch the panel. Identifies which characteristic, if any, the device acts on.
              inspect prints SDP services and RFCOMM channel IDs for a paired device.
              probe-rfcomm bypasses SDP and directly attempts RFCOMM channels 1 through 8 by default.
              send-hex connects to the first paired non-audio Timebox candidate unless --name or --address is supplied.
            """
        )
    }
}

private struct ParsedOptions {
    var name: String?
    var address: String?
    var uuid: UUID?
    var serviceUUID: String?
    var characteristicUUID: String?
    var channel: UInt8?
    var channels: [UInt8] = []
    var seconds: UInt8?
    var brightness: Int?
    var holdMilliseconds: Int?
    var requestSettings = false
    var writeModePreference: BLEWriteModePreference = .automatic
    var useMock = false
    var hexInput = ""

    init(arguments: [String], requiresHex: Bool) throws {
        var hexParts: [String] = []
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--name":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--name")
                }
                name = arguments[nextIndex]
                index = arguments.index(after: nextIndex)
            case "--address":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--address")
                }
                address = arguments[nextIndex]
                index = arguments.index(after: nextIndex)
            case "--uuid":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--uuid")
                }
                guard let parsedUUID = UUID(uuidString: arguments[nextIndex]) else {
                    throw CLIError.invalidUUID(arguments[nextIndex])
                }
                uuid = parsedUUID
                index = arguments.index(after: nextIndex)
            case "--service":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--service")
                }
                serviceUUID = arguments[nextIndex]
                index = arguments.index(after: nextIndex)
            case "--characteristic":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--characteristic")
                }
                characteristicUUID = arguments[nextIndex]
                index = arguments.index(after: nextIndex)
            case "--channel":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--channel")
                }
                channel = try Self.parseChannel(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            case "--channels":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--channels")
                }
                channels = try Self.parseChannels(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            case "--seconds":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--seconds")
                }
                seconds = try Self.parseSeconds(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            case "--brightness":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--brightness")
                }
                brightness = try Self.parseBrightness(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            case "--hold-ms":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIError.missingValue("--hold-ms")
                }
                holdMilliseconds = try Self.parseHoldMilliseconds(arguments[nextIndex])
                index = arguments.index(after: nextIndex)
            case "--with-response":
                writeModePreference = .withResponse
                index = arguments.index(after: index)
            case "--without-response":
                writeModePreference = .withoutResponse
                index = arguments.index(after: index)
            case "--request-settings":
                requestSettings = true
                index = arguments.index(after: index)
            case "--mock":
                useMock = true
                index = arguments.index(after: index)
            default:
                hexParts.append(argument)
                index = arguments.index(after: index)
            }
        }

        hexInput = hexParts.joined(separator: " ")
        if requiresHex, hexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError.missingHex
        }
    }

    private static func parseChannel(_ value: String) throws -> UInt8 {
        guard let channel = UInt8(value), channel > 0 else {
            throw CLIError.invalidChannel(value)
        }
        return channel
    }

    private static func parseChannels(_ value: String) throws -> [UInt8] {
        let separators = CharacterSet(charactersIn: ", ")
        let parts = value.components(separatedBy: separators).filter { !$0.isEmpty }
        let channels = try parts.map(parseChannel)
        guard !channels.isEmpty else {
            throw CLIError.invalidChannel(value)
        }
        return channels
    }

    private static func parseSeconds(_ value: String) throws -> UInt8 {
        guard let seconds = UInt8(value), seconds > 0 else {
            throw CLIError.invalidSeconds(value)
        }
        return seconds
    }

    private static func parseBrightness(_ value: String) throws -> Int {
        guard let brightness = Int(value), (0...100).contains(brightness) else {
            throw CLIError.invalidBrightness(value)
        }
        return brightness
    }

    private static func parseHoldMilliseconds(_ value: String) throws -> Int {
        guard let hold = Int(value), hold >= 0 else {
            throw CLIError.invalidHoldMilliseconds(value)
        }
        return hold
    }
}

private enum CLIError: LocalizedError {
    case missingValue(String)
    case missingHex
    case missingBrightness
    case invalidBrightness(String)
    case missingColor
    case invalidColor(String)
    case missingImagePath
    case missingDeviceSelector(String)
    case invalidChannel(String)
    case invalidSeconds(String)
    case invalidHoldMilliseconds(String)
    case invalidUUID(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .missingHex:
            return "Missing raw hex bytes. Example: timeboxctl send-hex \"AA BB CC\""
        case .missingBrightness:
            return "Missing brightness value. Example: timeboxctl brightness 50"
        case .invalidBrightness(let value):
            return "Invalid brightness '\(value)'. Use an integer from 0 through 100."
        case .missingColor:
            return "Missing color. Example: timeboxctl color FF0000"
        case .invalidColor(let value):
            return "Invalid color '\(value)'. Use a 6-digit RGB hex value, for example FF0000."
        case .missingImagePath:
            return "Missing image path. Example: timeboxctl image test.png --address AA-BB-CC-DD-EE-FF"
        case .missingDeviceSelector(let command):
            return "Missing device selector for \(command). Use --name or --address."
        case .invalidChannel(let value):
            return "Invalid RFCOMM channel '\(value)'. Use integers from 1 through 255."
        case .invalidSeconds(let value):
            return "Invalid scan duration '\(value)'. Use an integer number of seconds."
        case .invalidHoldMilliseconds(let value):
            return "Invalid hold duration '\(value)'. Use a non-negative integer number of milliseconds."
        case .invalidUUID(let value):
            return "Invalid UUID '\(value)'."
        }
    }
}

final class ExitCodeBox: @unchecked Sendable {
    var value: Int32 = 1
}

let cliArguments = Array(CommandLine.arguments.dropFirst())
let cliCommand = cliArguments.first
let cliIsMock = cliArguments.contains("--mock")
let cliHasAddress = cliArguments.contains("--address")
let classicSyncCommands: Set<String> = ["connect", "send-hex", "probe-rfcomm"]
// color/brightness use Classic SPP when targeted by --address, BLE when --uuid.
// repl/image are always Classic SPP.
let sppCapableCommands: Set<String> = ["color", "brightness", "image", "repl"]

let routeClassic: Bool = {
    guard let cliCommand, !cliIsMock else { return false }
    if classicSyncCommands.contains(cliCommand) { return true }
    return sppCapableCommands.contains(cliCommand) && cliHasAddress
}()

let exitCode: Int32
if routeClassic, let cliCommand {
    // Classic IOBluetooth path: run on the main thread so the main run loop
    // (which IOBluetooth delivers RFCOMM callbacks to) can be pumped.
    exitCode = TimeboxCLI.runClassicSync(command: cliCommand, arguments: Array(cliArguments.dropFirst()))
} else {
    // Everything else (BLE + sync) via the async runtime, bridged to a blocking
    // call so `exit` runs after completion. BLE uses its own dispatch queue, so
    // blocking the main thread here is fine.
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ExitCodeBox()
    Task.detached(priority: .userInitiated) {
        resultBox.value = await TimeboxCLI.run(arguments: cliArguments)
        semaphore.signal()
    }
    semaphore.wait()
    exitCode = resultBox.value
}
exit(exitCode)
