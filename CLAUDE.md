# CLAUDE.md

Handoff notes for the Timebox Studio project.

Current date/context: June 3, 2026. Workspace root:

```text
/Users/marcovhv/Documents/TimeBox
```

## Project Goal

Build a native macOS SwiftUI prototype called **Timebox Studio** that controls a Divoom Timebox Evo 16x16 RGB LED display directly from the Mac.

Hard constraints:

- Native macOS, Swift/SwiftUI.
- No official Divoom app dependency.
- No Node runtime dependency.
- No Electron/web app/web server.
- No Raspberry Pi or ESP32 as the control path.
- Keep protocol encoding separate from transport.
- Keep raw hex sending available from day one.

Original assumption was Bluetooth Classic RFCOMM through Apple's `IOBluetooth`. Real hardware testing now shows the LED/control side is reachable over BLE, through a Microchip/ISSC-style Transparent UART service.

## Repository State

This is a Swift Package Manager project with a lightweight Xcode workspace.

Important paths:

```text
Package.swift
README.md
DEVELOPMENT_NOTES.md
CLAUDE.md
TimeboxStudio.xcworkspace/contents.xcworkspacedata

TimeboxStudio/
  App/
    TimeboxStudioApp.swift
    AppState.swift
  UI/
    MainWindowView.swift
    DevicePickerView.swift
    ConnectionPanelView.swift
    DebugLogView.swift
    RawHexSenderView.swift
    BrightnessControlView.swift
    PixelEditorView.swift
    ImportImageView.swift
    AnimationTimelineView.swift
  Bluetooth/
    TimeboxDevice.swift
    BluetoothDeviceScanner.swift
    BluetoothDeviceInspector.swift
    CoreBluetoothDeviceScanner.swift
    CoreBluetoothTimeboxClient.swift
    TimeboxTransport.swift
    MockTimeboxTransport.swift
    IOBluetoothTimeboxTransport.swift
    RFCOMMChannelDelegateBridge.swift
  TimeboxKit/
    PixelRGB.swift
    PixelFrame.swift
    TimeboxCommand.swift
    TimeboxPacketEncoder.swift
    TimeboxChecksum.swift
    TimeboxByteEscaper.swift
    TimeboxDebugFormatter.swift
    ImageToPixelFrameConverter.swift
  Persistence/
    SavedDesign.swift
    DesignStore.swift
  Utilities/
    Logger.swift
    HexDump.swift

timeboxctl/
  main.swift
  Info.plist

TimeboxStudioTests/
  HexStringParserTests.swift
  PixelFrameTests.swift
  TimeboxPacketEncoderTests.swift
```

Current git status at handoff: all project files are untracked. Nothing has been committed or staged.

## What Builds

Known-good commands:

```sh
swift build
swift test
```

Last known test result:

```text
8 tests, 0 failures
```

Prefer running the built CLI directly for Bluetooth/TCC reasons:

```sh
.build/debug/timeboxctl ...
```

`swift run timeboxctl ...` can interact poorly with macOS privacy/TCC launch behavior.

## Implemented Features

SwiftUI app shell:

- Device list.
- Refresh devices.
- Connect/disconnect.
- Connection status.
- Brightness slider.
- Send Brightness button.
- Clear Display placeholder.
- Raw hex sender.
- Debug log panel.
- Last packet hex output.

Transport/probing:

- `TimeboxTransport` protocol.
- `MockTimeboxTransport`.
- `IOBluetoothTimeboxTransport` for Classic RFCOMM.
- Paired Classic device listing.
- Classic inquiry command exists but timed out during real testing.
- BLE advertisement scanner.
- BLE GATT inspector.
- BLE raw writer.
- BLE brightness writer.

CLI commands currently implemented:

```sh
.build/debug/timeboxctl list
.build/debug/timeboxctl scan
.build/debug/timeboxctl scan-ble
.build/debug/timeboxctl inspect
.build/debug/timeboxctl inspect-ble
.build/debug/timeboxctl probe-rfcomm
.build/debug/timeboxctl connect
.build/debug/timeboxctl send-hex
.build/debug/timeboxctl send-ble-hex
.build/debug/timeboxctl brightness
.build/debug/timeboxctl brightness-ble
```

BLE write flags:

```sh
--with-response
--without-response
```

If neither flag is provided, `CoreBluetoothTimeboxClient` currently defaults to `writeWithoutResponse` for the Transparent UART RX characteristic when available.

## Hardware Observations

User's Timebox Evo appears as two different things:

Classic/audio side:

```text
Timebox-Evo-audio
address: b1-21-81-41-c0-f0
paired: yes
connected: yes
source: bluetooth
```

This is not the LED control endpoint.

BLE/light side:

```text
Timebox-Evo-light
uuid: BE32D255-6999-AE59-4577-4F5BDA0458D3
advertised name: Timebox-Evo-light
rssi: about -41
connectable: yes
advertised service: AF30
```

Important: CoreBluetooth UUIDs are macOS-local identifiers. If the device is forgotten/re-paired, rediscover with:

```sh
.build/debug/timeboxctl scan-ble --seconds 15
```

## BLE GATT Discovery

`inspect-ble` found this service:

```text
49535343-FE7D-4AE5-8FA9-9FAFD205E455
```

Characteristics:

```text
49535343-ACA3-481C-91EC-D85E28A60318
  properties: write, notify
  read: no
  write: yes
  write without response: no
  notify/indicate: yes

49535343-6DAA-4D02-ABF6-19569ACA69FE
  properties: read
  read: yes
  write: no
  write without response: no
  notify/indicate: no

49535343-8841-43F4-A8D4-ECBE34729BB3
  properties: writeWithoutResponse, write
  read: no
  write: yes
  write without response: yes
  notify/indicate: no

49535343-1E4D-4BD9-BA61-23C647249616
  properties: writeWithoutResponse, notify
  read: no
  write: no
  write without response: yes
  notify/indicate: yes
```

Microchip RN4870/71 Transparent UART reference:

- Service UUID: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- TX characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`
- RX characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`

The discovered Timebox service matches that profile. Source:

```text
https://ww1.microchip.com/downloads/aemDocuments/documents/OTH/ProductDocuments/UserGuides/RN4870-71-Bluetooth-Low-Energy-Module-User-Guide-DS50002466C.pdf
```

The advertised `AF30` service is not the service returned by GATT discovery. The client supports `--service AF30`, but when that yields no discovered service it falls back to discovering all services.

## Protocol Reference

Primary protocol reference:

```text
https://raw.githubusercontent.com/RomRider/node-divoom-timebox-evo/master/PROTOCOL.md
```

Useful package docs:

```text
https://romrider.github.io/node-divoom-timebox-evo/docs/
```

Another useful corroborating reference:

```text
https://github.com/d03n3rfr1tz3/esp32-divoom
```

That ESP32 Divoom proxy shows the same brightness packets:

```text
0104007432AA0002
0104007464DC0002
```

## Implemented Packet Encoding

Only brightness is implemented as a real protocol command.

Packet structure from PROTOCOL.md:

```text
01 LLLL PAYLOAD CRCR 02
```

Rules:

- Start marker: `01`
- End marker: `02`
- `LLLL` is little-endian length of `PAYLOAD + 2 checksum bytes`.
- `CRCR` is little-endian byte sum of `LLLL PAYLOAD`.
- No byte escaping is implemented. `TimeboxByteEscaper` is still placeholder/pass-through.

Brightness payload:

```text
74 BB
```

`BB` is brightness from 0 to 100 decimal.

Examples:

```text
brightness 0:
payload: 74 00
packet:  01 04 00 74 00 78 00 02

brightness 50:
payload: 74 32
packet:  01 04 00 74 32 AA 00 02

brightness 100:
payload: 74 64
packet:  01 04 00 74 64 DC 00 02
```

Tests cover brightness 0, 50, 100, checksum, and out-of-range rejection.

## Real Device Test Results

BLE write works at the GATT layer.

User ran brightness command and got:

```text
Wrote 8 byte(s) over BLE.
    peripheral: BE32D255-6999-AE59-4577-4F5BDA0458D3
    service: 49535343-FE7D-4AE5-8FA9-9FAFD205E455
    characteristic: 49535343-8841-43F4-A8D4-ECBE34729BB3
    write type: withResponse
```

Then user tried brightness 0 and 100:

```text
raw packet: 01 04 00 74 00 78 00 02
Wrote 8 byte(s) over BLE.

raw packet: 01 04 00 74 64 DC 00 02
Wrote 8 byte(s) over BLE.
```

Observed result:

```text
No visible change on the device.
```

After adding `--without-response` and alternate-characteristic probes, user still reported:

```text
I saw nothing on the device.
```

Interpretation:

- Bluetooth discovery/connect/write is proven.
- The known Classic/RFCOMM brightness packet is probably correct.
- The Timebox light endpoint is either:
  - ignoring this packet on BLE without some setup/handshake,
  - expecting a different characteristic,
  - expecting notifications/subscriptions enabled first,
  - expecting a different BLE framing/envelope,
  - in a mode where brightness writes are accepted but not visibly applied,
  - or the BLE endpoint is not the same raw serial pipe exposed by Classic/RFCOMM despite matching Transparent UART UUIDs.

Do not spend time reworking the checksum unless new evidence appears. The packet bytes match two independent Divoom references.

## Important Current Limitation

The SwiftUI app still uses `TimeboxTransport`, which currently routes real hardware through Classic RFCOMM, not the discovered BLE path.

The verified BLE discovery/write path is currently exposed through `timeboxctl` via `CoreBluetoothTimeboxClient`.

Next app-level architecture step should be a BLE transport implementation, for example:

```text
CoreBluetoothTimeboxTransport.swift
```

conforming to:

```swift
protocol TimeboxTransport {
    var isConnected: Bool { get }
    func connect(to device: TimeboxDevice) async throws
    func disconnect()
    func write(_ data: Data) async throws
}
```

But before doing UI work, fix the no-visible-effect problem with the CLI.

## Suggested Next Debugging Plan

Priority 1: capture notifications/readback.

Implement a BLE listen/test harness:

```sh
.build/debug/timeboxctl listen-ble --uuid BE32D255-6999-AE59-4577-4F5BDA0458D3
```

It should:

- Connect to the BLE peripheral.
- Discover all services.
- Subscribe to notify characteristics:
  - `49535343-1E4D-4BD9-BA61-23C647249616`
  - `49535343-ACA3-481C-91EC-D85E28A60318`
- Read readable characteristic:
  - `49535343-6DAA-4D02-ABF6-19569ACA69FE`
- Print all notifications as timestamped hex and ASCII.
- Keep the connection open for at least 10-30 seconds.
- Optionally send a packet while notifications are enabled.

Priority 2: test a readback command.

The protocol request-settings payload is:

```text
46
```

Expected full packet, using current packet wrapper:

```text
01 03 00 46 49 00 02
```

Try sending that while subscribed to notifications. If the device responds, we know the BLE pipe is actually feeding the Timebox protocol parser.

Priority 3: systematically probe characteristics and write modes with a persistent connection.

Add:

```sh
.build/debug/timeboxctl probe-ble-write --uuid ... "01 04 00 74 64 DC 00 02"
```

It should try:

- `8841...BB3` with response.
- `8841...BB3` without response.
- `1E4D...9616` without response.
- `ACA3...0318` with response.

For each attempt:

- Keep notifications enabled.
- Print write result.
- Print any notification response.
- Wait at least 1 second before disconnecting.

Priority 4: try a visibly obvious command other than brightness.

Brightness may be ignored while the device is in some display state. A channel/light command or tiny image may be more obvious.

From PROTOCOL.md, lightning channel plain color is:

```text
45 01 RRGGBB BB TT PP 00 00 00
```

Where:

- `RRGGBB`: color.
- `BB`: brightness 0-100.
- `TT`: type, `00` is plain color.
- `PP`: power, usually `01`.

Do not overbuild this yet. Add a raw/encoder helper only if it helps test a visible state change.

Priority 5: investigate handshake/framing.

Possibilities:

- BLE connection needs notification subscription before writes are forwarded.
- One of the nonstandard characteristics (`ACA3`, `6DAA`) is a mode/control characteristic.
- The Divoom app sends an initialization command before Timebox protocol packets.
- The BLE Transparent UART module is connected but host MCU ignores commands until some state is set.
- The official app may use BLE with a different envelope than the Classic serial protocol.

Best tools:

- Add notification capture first.
- If available, sniff official app traffic with Bluetooth tools.
- Test with a BLE explorer such as nRF Connect to confirm characteristic behavior manually.
- If using Android, capture Bluetooth HCI snoop logs from the official app session.

## Commands To Resume Quickly

Build/test:

```sh
cd /Users/marcovhv/Documents/TimeBox
swift build
swift test
```

Discover light endpoint:

```sh
.build/debug/timeboxctl scan-ble --seconds 15
```

Inspect known endpoint:

```sh
.build/debug/timeboxctl inspect-ble --uuid BE32D255-6999-AE59-4577-4F5BDA0458D3
```

Current brightness test:

```sh
.build/debug/timeboxctl brightness 100 --uuid BE32D255-6999-AE59-4577-4F5BDA0458D3 --without-response
```

Raw request-settings test to try after implementing notification listening:

```sh
.build/debug/timeboxctl send-ble-hex --uuid BE32D255-6999-AE59-4577-4F5BDA0458D3 --characteristic 49535343-8841-43F4-A8D4-ECBE34729BB3 --without-response "01 03 00 46 49 00 02"
```

## Development Style Notes

- Use `rg`/`rg --files` first for searches.
- Use `apply_patch` for manual edits.
- Do not rewrite the project into Xcode-only format unless needed.
- Keep raw hex sender and CLI probes. They are the escape hatch.
- Keep protocol code in `TimeboxStudio/TimeboxKit`.
- Keep Bluetooth transport/probing code in `TimeboxStudio/Bluetooth`.
- Keep UI polish secondary until hardware effects are visible.
- Do not delete Classic RFCOMM code yet; it may still matter for some Timebox variants or future comparison.

## High-Level Status

We are past device discovery and past BLE writes. The project is at the harder, more interesting point:

```text
macOS -> BLE peripheral -> GATT write succeeds -> Timebox display does not react
```

Next success criterion is not prettier UI. It is one visible hardware effect, ideally from a CLI command, with notification logs proving what the device did or did not say back.
