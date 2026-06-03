# Timebox Studio

Control a Divoom **Timebox Evo** (16×16 RGB LED display) directly from macOS — send
arbitrary images, solid colors, and brightness — with **no Divoom app, no Node, no
Electron/web server, and no ESP32/Raspberry Pi** in the control path. Pure Swift over
Apple's native Bluetooth stack.

It is primarily a **Swift library** (`TimeboxClient`) you can build apps on top of,
plus a command-line tool (`timeboxctl`) and a minimal SwiftUI shell.

## How it works (short version)

The Timebox Evo's LED protocol runs over **Bluetooth Classic SPP/RFCOMM** — *not* BLE.
(The device also advertises a BLE "Transparent UART" endpoint, but it is not wired to
the LED protocol; chasing it is a dead end.) The wire format and the image encoding
were reverse-engineered from the official Divoom Android app and re-implemented natively
with `IOBluetooth`. See [`DEVELOPMENT_NOTES.md`](DEVELOPMENT_NOTES.md) for the protocol.

## Requirements

- macOS (Apple Silicon or Intel), Swift 5.9+
- A Divoom Timebox Evo **paired** with your Mac in **System Settings → Bluetooth**
  (one-time, manual — it shows up as e.g. `Timebox-Evo-audio`). Pairing is the only
  step that can't be automated.

## Build & test

```sh
swift build
swift test
```

## Use the CLI

List paired devices to find your Timebox's address:

```sh
.build/debug/timeboxctl list
```

Send an image / color / brightness (the RFCOMM channel is auto-resolved from the
device's SDP — no need to specify one):

```sh
.build/debug/timeboxctl image art.png   --address <MAC>
.build/debug/timeboxctl color FF0000     --address <MAC>
.build/debug/timeboxctl brightness 40    --address <MAC>
```

Interactive mode — one persistent connection, stream commands:

```sh
.build/debug/timeboxctl repl --address <MAC>
# then type:  image art.png  |  color 00FF00  |  brightness 25  |  quit
```

> If a command times out connecting to the SPP channel, macOS is probably holding it
> for the paired speaker — **power-cycle the Timebox** and retry.

## Use as a library

Add this package as a SwiftPM dependency and import `TimeboxBluetooth` (+ `TimeboxKit`):

```swift
import TimeboxBluetooth
import TimeboxKit

let client = TimeboxClient()

// Find the user's Timebox among paired Bluetooth devices:
guard let timebox = TimeboxClient.discoverTimeboxes().first else {
    print("No paired Timebox found — pair it in System Settings → Bluetooth first.")
    return
}

try await client.connect(to: timebox)         // SPP channel auto-resolved from SDP
try await client.send(imageAt: "art.png")      // any PNG/JPG/BMP/GIF -> 16×16
try await client.setColor(PixelRGB(red: 255, green: 0, blue: 0))
try await client.setBrightness(60)
client.disconnect()
```

Call the async methods from a context with a running run loop (any AppKit/SwiftUI app).
The connection is **persistent** — connect once, then push images/colors at any time.

### Finding the device ("will this work with anyone's Timebox?")

Yes — nothing is hardcoded to one device:

- `TimeboxClient.discoverTimeboxes()` — paired devices whose name contains "Timebox".
- `TimeboxClient.pairedDevices()` — *all* paired devices, so you can present your own picker.
- The Bluetooth **address** comes from discovery; the **RFCOMM channel** is resolved per
  device from its SDP (Serial Port Profile, UUID `0x1101`), exactly like the official app.

So any user's Timebox Evo works once they've paired it with their Mac.

## Library products

- **`TimeboxKit`** — protocol encoding (`TimeboxPacketEncoder`, `TimeboxImageEncoder`),
  `PixelFrame`/`PixelRGB`, and `ImageToPixelFrameConverter` (PNG/JPG → 16×16, CoreGraphics).
- **`TimeboxBluetooth`** — `TimeboxClient` (high-level API), `IOBluetoothTimeboxTransport`
  (Classic SPP), and paired-device discovery.

## Project layout

```text
TimeboxStudio/
  TimeboxKit/        protocol encoding + image conversion (platform-light)
  Bluetooth/         TimeboxClient, IOBluetooth SPP transport, discovery, diagnostics
  Persistence/       SavedDesign / DesignStore
  Utilities/         hex parsing, logging
  App/ UI/           minimal SwiftUI shell
timeboxctl/          command-line tool
TimeboxStudioTests/  packet + image encoding tests
```

## Status

- ✅ Images, solid color, brightness — working on real hardware.
- ⬜ Not yet: GIF/animation, a full pixel-editor GUI (the SwiftUI shell is minimal),
  saved-design persistence wired into the UI.

## Constraints honored

Native macOS Swift only; no Divoom app, Node, Electron/web, or ESP32/Pi in the control
path; protocol encoding kept separate from transport; a raw-hex escape hatch is retained.
