# CLAUDE.md

Handoff notes for the Timebox Studio project. Workspace root:
`/Users/marcovhv/projects/GIT/TimeBox` (a Swift Package + lightweight Xcode workspace).

## Status: SOLVED (macOS + iOS)

Native control of a Divoom **Timebox Evo** (16×16 LED display) works end to end on both
**macOS and iOS** — solid color, brightness, and **arbitrary 16×16 images** render on
real hardware. No Divoom app, Node, Electron, or microcontroller.

- **macOS:** **Bluetooth Classic SPP/RFCOMM**, driven with `IOBluetooth`.
- **iOS:** **BLE** (`CoreBluetooth`). IOBluetooth doesn't exist on iOS, so the BLE
  "Transparent UART" endpoint *is* the path — but only via the JieLi **RCSP** wrapper and
  the device's `01` command channel (see Protocol below). The earlier "BLE is a dead end"
  note was only true for sending raw SPP frames straight at the endpoint; wrapped in RCSP
  and tunneled through the `01` channel it works. `CoreBluetoothRCSPTransport` implements it.

`TimeboxClient` picks the transport per platform; the app-facing API is identical.

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
TimeboxBluetooth   transport + high-level API — TimeboxClient (per-platform transport),
                   IOBluetoothTimeboxTransport (macOS Classic SPP, #if canImport(IOBluetooth)),
                   CoreBluetoothRCSPTransport (iOS/macOS BLE via RCSP), BluetoothDeviceScanner
                   (discovery), plus the CoreBluetooth* BLE diagnostic code (reference)
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

### iOS BLE (CoreBluetoothRCSPTransport)

- Service `49535343-FE7D-…`; write (no-response) to RX `…8841` (handle 0x000d); notify on
  TX `…1E4D` (handle 0x000f). The Timebox is also a BT speaker, so iOS often already holds
  it connected (then it stops advertising) — `retrieveConnectedPeripherals` attaches; else scan by name.
- **`TimeboxClient` hands every command down as a full SPP frame; the transport strips the
  envelope and re-wraps it.** RCSP frame: `FE EF AA 55 | LEN(LE16) | 01 <seq> 00 00 00
  <SPP payload> | SUM16(LEN+body)(LE16)`, `LEN = body+2`, same sum16 as SPP. `seq`
  increments per command from 1 on connect; device ACKs with SPP notify `01 .. 04 33 55 <seq> ..`.
- **Dead ends (don't retry):** the `00 01 <json>` (e.g. `Device/SetUTC`) and `00 9E <seq>
  <frame>` channels are ACKed but only render in the app's live "Draw sync" design mode.
  The `01` channel runs ordinary SPP commands with no handshake — use it.

## Protocol (reverse-engineered from the official Android APK + an iOS BLE capture)

Frame: `01 LEN(LE16) CMD payload CRC(LE16) 02`, `LEN = payload.len + 2`,
`CRC = sum(LEN + payload bytes) & 0xFFFF`. No byte-stuffing (the Evo is "NewMode").
Implemented byte-for-byte in `TimeboxPacketEncoder` (matches `node-divoom-timebox-evo`).
The iOS BLE path wraps these exact frames' payloads in RCSP (above).

Key opcodes: brightness `0x74` (`74 BB`); plain color `0x45`
(`45 01 RRGGBB level type power 00 00 00`); image `0x44`. Image payload (see
`TimeboxImageEncoder`): `44 00 0A 0A 04 | AA LLLL(LE) 00 00 00 | NN | <palette RGB> |
<pixels>`, palette = unique colors first-seen, pixels = indices packed LSB-first with
`max(1, ceil(log2(NN)))` bits, row-major top-left first. The native `pixelEncode` is in
the APK's NDK `.so`; the documented equivalent lives in `node-divoom-timebox-evo`.

## What's next (optional)

GIF/animation (`0x44`/`0x49` multi-frame, chunked); large-image MTU chunking if a
256-color image ever fails to render. The iOS `timebox-ios` app is a thin `TimeboxClient`
consumer (separate repo at `../timebox-ios`).

## Conventions

- `rg` for search; keep protocol code in `TimeboxKit`, transport in `Bluetooth`.
- The decompiled `apk/` and `/tmp/divoom_src` (jadx output) are reference only and are
  git-ignored (copyrighted). Keep the raw-hex sender / CLI probes as an escape hatch.
