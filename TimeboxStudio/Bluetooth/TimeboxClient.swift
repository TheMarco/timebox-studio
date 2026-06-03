import Foundation
import TimeboxKit

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// High-level entry point for apps built on top of this library.
///
/// Workflow: discover the user's paired Timebox, open a persistent Bluetooth
/// Classic SPP connection, then push images / colors / brightness at any time
/// until `disconnect()`.
///
/// ```swift
/// let client = TimeboxClient()
/// guard let timebox = TimeboxClient.discoverTimeboxes().first else { /* ask user to pair */ }
/// try await client.connect(to: timebox)          // SPP channel auto-resolved from SDP
/// try await client.send(imageAt: "/path/to/art.png")
/// try await client.setBrightness(60)
/// client.disconnect()
/// ```
///
/// The async methods deliver IOBluetooth callbacks on the main run loop, so call
/// them from a context with a running run loop (any AppKit/SwiftUI app). Nothing
/// is hardcoded to a specific device: the Bluetooth address comes from discovery
/// and the RFCOMM channel is resolved per device from its SDP records.
public final class TimeboxClient {
    private let transport = IOBluetoothTimeboxTransport()

    public init() {}

    public var isConnected: Bool { transport.isConnected }

    // MARK: - Discovery

    /// All paired Bluetooth devices — present these so the user can pick their
    /// Timebox (the control endpoint is the audio-side device, e.g. `Timebox-Evo-audio`).
    public static func pairedDevices() -> [TimeboxDevice] {
        BluetoothDeviceScanner.scanPairedDevices(includeMock: false).devices
    }

    /// Paired devices whose name looks like a Timebox — a convenience filter over
    /// `pairedDevices()`. The user must have paired the device in macOS first.
    public static func discoverTimeboxes() -> [TimeboxDevice] {
        pairedDevices().filter { $0.name.range(of: "timebox", options: .caseInsensitive) != nil }
    }

    // MARK: - Connection

    /// Connect to a discovered device. The SPP RFCOMM channel is auto-resolved
    /// from the device's SDP (pass `channel` only to force a specific one).
    public func connect(to device: TimeboxDevice, channel: UInt8? = nil) async throws {
        if let channel {
            try await transport.connect(to: device, channelID: channel)
        } else {
            try await transport.connect(to: device)
        }
    }

    /// Connect by Bluetooth address (e.g. `"AA-BB-CC-DD-EE-FF"`). Channel is
    /// auto-resolved unless provided.
    public func connect(address: String, channel: UInt8? = nil) async throws {
        let device = TimeboxDevice(
            name: "Timebox \(address)",
            address: address,
            isPaired: true,
            isConnected: false,
            source: .bluetooth
        )
        try await connect(to: device, channel: channel)
    }

    public func disconnect() {
        transport.disconnect()
    }

    // MARK: - Sending (connection must be open)

    /// Display an arbitrary 16x16 image.
    public func send(image frame: PixelFrame) async throws {
        try await transport.write(try TimeboxPacketEncoder.encode(.image(frame)))
    }

    #if canImport(CoreGraphics)
    /// Load an image file (PNG/JPG/BMP/GIF), rasterize to 16x16, and display it.
    public func send(imageAt path: String) async throws {
        try await send(image: try ImageToPixelFrameConverter.loadPixelFrame(path: path))
    }

    /// Rasterize a `CGImage` to 16x16 and display it.
    public func send(cgImage: CGImage) async throws {
        try await send(image: try ImageToPixelFrameConverter.pixelFrame(from: cgImage))
    }
    #endif

    /// Fill the whole display with a single color.
    public func setColor(_ color: PixelRGB, brightnessPercent: Int = 100) async throws {
        try await transport.write(
            try TimeboxPacketEncoder.encode(.lightningPlainColor(color: color, brightnessPercent: brightnessPercent))
        )
    }

    /// Set the display brightness (0...100).
    public func setBrightness(_ percent: Int) async throws {
        try await transport.write(try TimeboxPacketEncoder.encode(.setBrightness(percent)))
    }

    /// Send a raw, already-framed protocol packet (escape hatch).
    public func sendRaw(_ packet: Data) async throws {
        try await transport.write(packet)
    }
}
