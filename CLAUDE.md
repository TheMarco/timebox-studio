# CLAUDE.md

Handoff notes for the Timebox Studio project. Workspace root:
`/Users/marcovhv/projects/GIT/TimeBox` (a Swift Package + lightweight Xcode workspace).

## Status: SOLVED

Native macOS control of a Divoom **Timebox Evo** (16×16 LED display) works end to end —
solid color, brightness, and **arbitrary 16×16 images** render on real hardware. No
Divoom app, Node, Electron, or microcontroller.

The control path is **Bluetooth Classic SPP/RFCOMM**, driven with `IOBluetooth`. The
BLE "Transparent UART" endpoint the device advertises is a dead end (not wired to the
LED protocol) — don't revisit it.

## Build / test / run

```sh
swift build
swift test                       # 12 tests
.build/debug/timeboxctl list     # find paired devices
.build/debug/timeboxctl image art.png --address <MAC>
.build/debug/timeboxctl repl --address <MAC>
```

Prefer the built binary (`.build/debug/timeboxctl`) over `swift run` for Bluetooth/TCC
reasons. Classic Bluetooth commands run synchronously on the main thread and pump the
main run loop (see transport notes); BLE/diagnostic commands run via the async runtime.

## Architecture

```text
TimeboxUtilities   hex parsing, hex dump, logging (leaf)
TimeboxKit         protocol encoding ONLY — PixelFrame/PixelRGB, TimeboxCommand,
                   TimeboxPacketEncoder, TimeboxImageEncoder, TimeboxChecksum,
                   ImageToPixelFrameConverter (PNG/JPG -> 16x16, CoreGraphics)
TimeboxBluetooth   transport + high-level API — TimeboxClient, IOBluetoothTimeboxTransport
                   (Classic SPP), BluetoothDeviceScanner (discovery), plus the
                   CoreBluetooth* BLE diagnostic code (kept for reference)
TimeboxPersistence SavedDesign / DesignStore
TimeboxStudio      minimal SwiftUI app shell        timeboxctl  CLI
```

Encoding stays separate from transport. The library products are `TimeboxKit` and
`TimeboxBluetooth`; apps consume those (see README "Use as a library").

## How control works

- **Transport:** Classic SPP. `IOBluetoothTimeboxTransport.connectPumpingRunLoop` /
  `writePumpingRunLoop` (CLI, main-thread run-loop-pumped) and async `connect`/`write`
  (apps with a running run loop). IOBluetooth delivers RFCOMM callbacks on the **main**
  run loop — the original bug was calling the *sync* APIs from a GCD thread with no run
  loop; the fix uses the **async** open/write APIs and pumps/awaits the main run loop.
- **Device discovery:** `TimeboxClient.discoverTimeboxes()` (paired devices named
  "Timebox") / `pairedDevices()`. Pairing itself is manual (macOS Bluetooth settings).
- **Channel:** auto-resolved per device from SDP via the Serial Port Profile UUID
  `0x1101` (`IOBluetoothDevice.getServiceRecord(for:)` → `getRFCOMMChannelID`), matching
  the app's `createInsecureRfcommSocketToServiceRecord`. `--channel` overrides.
- **Gotcha:** macOS auto-grabs the SPP channel for the paired speaker; if connect times
  out, **power-cycle the Timebox**. A second JL_SPP channel opens but is a dead endpoint.
- **Reliability:** the device drops commands if the channel is torn down mid-parse, so
  one-shot sends settle/hold around the write; the `repl` keeps one persistent connection.

## Protocol (reverse-engineered from the official Android APK)

Frame: `01 LEN(LE16) CMD payload CRC(LE16) 02`, `LEN = payload.len + 2`,
`CRC = sum(LEN + payload bytes) & 0xFFFF`. No byte-stuffing (the Evo is "NewMode").
Implemented byte-for-byte in `TimeboxPacketEncoder` (matches `node-divoom-timebox-evo`).

Key opcodes: brightness `0x74` (`74 BB`); plain color `0x45`
(`45 01 RRGGBB level type power 00 00 00`); image `0x44`. Image payload (see
`TimeboxImageEncoder`): `44 00 0A 0A 04 | AA LLLL(LE) 00 00 00 | NN | <palette RGB> |
<pixels>`, palette = unique colors first-seen, pixels = indices packed LSB-first with
`max(1, ceil(log2(NN)))` bits, row-major top-left first. The native `pixelEncode` is in
the APK's NDK `.so`; the documented equivalent lives in `node-divoom-timebox-evo`.

## What's next (optional)

GIF/animation (`0x44`/`0x49` multi-frame, chunked); wire the SwiftUI app's transport to
`TimeboxClient`; large-image MTU chunking if a 256-color image ever fails to render.

## Conventions

- `rg` for search; keep protocol code in `TimeboxKit`, transport in `Bluetooth`.
- The decompiled `apk/` and `/tmp/divoom_src` (jadx output) are reference only and are
  git-ignored (copyrighted). Keep the raw-hex sender / CLI probes as an escape hatch.
