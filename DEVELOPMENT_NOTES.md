# Development Notes

Protocol and implementation reference for controlling a Divoom Timebox Evo from macOS.
Reverse-engineered from the official Divoom Android app (decompiled with `jadx`) and
cross-checked against the open `node-divoom-timebox-evo` reimplementation.

## Transport: Bluetooth Classic SPP/RFCOMM

The LED protocol is carried over **Bluetooth Classic SPP** (Serial Port Profile,
RFCOMM) — the same channel the official app opens with
`createInsecureRfcommSocketToServiceRecord(00001101-0000-1000-8000-00805F9B34FB)`.
The device is a JieLi (JL) chip exposing `JL_SPP`; the LED endpoint is the **audio-side**
Bluetooth device (e.g. `Timebox-Evo-audio`).

The device's BLE "Transparent UART" endpoint (`Timebox-Evo-light`, ISSC/Microchip
`49535343-…` service) is **not** wired to the LED protocol — writes succeed at the GATT
layer but nothing renders, and a request-settings readback draws no reply. Dead end.

### IOBluetooth run loop (the key macOS pitfall)

IOBluetooth delivers RFCOMM open/write callbacks on the **main run loop**, not a dispatch
queue or an arbitrary thread's run loop. Calling the *synchronous* `openRFCOMMChannelSync`
from a GCD worker (no running run loop) lets the baseband connect but silently drops the
channel-negotiation callback → generic `kIOReturnError`. The fix
(`IOBluetoothTimeboxTransport`): use the **async** APIs (`openRFCOMMChannelAsync` +
`rfcommChannelOpenComplete`, `writeAsync` + `rfcommChannelWriteComplete`) and either pump
the main run loop (CLI: `connectPumpingRunLoop`/`writePumpingRunLoop`) or rely on the
app's already-running run loop (async `connect`/`write`).

### Channel resolution (device-agnostic)

Don't hardcode the channel. Resolve it per device from SDP:
`IOBluetoothDevice.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101))` then
`getRFCOMMChannelID(_:)`. This matches whatever channel that user's firmware uses.
`--channel` / the `channel:` argument overrides.

### Reliability

Per-command connect→write→close drops commands because tearing the channel down mid-parse
truncates the firmware. One-shot sends add a post-connect settle (~150 ms) and post-write
hold (default 500 ms, `--hold-ms`) plus connect retries; the `repl` holds **one persistent
connection** (the app's model) and never reconnects between commands.

### macOS quirk

macOS auto-connects the paired speaker and grabs its SPP channel; a fresh open then times
out. **Power-cycle the Timebox** to free it. A second `JL_SPP` channel opens but is a dead
secondary endpoint — don't fall back to it.

## Packet framing

```text
01  LEN(LE16)  CMD  PAYLOAD…  CRC(LE16)  02
```

- start `0x01`, end `0x02`.
- `LEN` = number of bytes in `CMD + PAYLOAD + CRC` = `payload.count + 2` (little-endian).
- `CRC` = `sum(LEN bytes + CMD + PAYLOAD) & 0xFFFF` (little-endian).
- Byte `[3]` is always the command opcode.

Two device modes exist in the app: **NewMode** (raw, no escaping) and **OldMode** (byte-
stuffs `01→03 04`, `02→03 05`, `03→03 06` between the markers). The **Timebox Evo is
NewMode** — confirmed because a raw color packet containing literal `0x01` bytes renders
correctly. `TimeboxPacketEncoder.encodePayload` implements NewMode and is byte-identical
to `node-divoom-timebox-evo`'s message framing. `TimeboxByteEscaper` is a placeholder for
OldMode if an older device ever needs it (algorithm above).

## Commands (`SppProc$CMD_TYPE`)

| Command            | Opcode      | Payload (after opcode)                              |
|--------------------|-------------|----------------------------------------------------|
| Set brightness     | `0x74` (116)| `BB` (0–100)                                        |
| Plain color        | `0x45` (69) | `01 RR GG BB level type power 00 00 00`             |
| Static image       | `0x44` (68) | see below                                           |

Examples: brightness 50 → `01 04 00 74 32 AA 00 02`; red fill →
`01 0D 00 45 01 FF 00 00 64 00 01 00 00 00 B7 01 02`.

## Static image encoding (`TimeboxImageEncoder`)

Inner payload (before the `01 … CRC 02` envelope):

```text
44 00 0A 0A 04   AA  LLLL(LE)  00 00 00   NN   <palette RGB…>   <packed pixels…>
```

- `44 00 0A 0A 04` — command + fixed static-image header.
- `AA` — frame marker; `LLLL` = full frame length (little-endian) = `6 + body.count`,
  where `body = NN + palette + packed pixels`.
- `00 00 00` — static-image time/reset bytes.
- `NN` = palette color count mod 256 (256 colors → `00`).
- palette — `NN` unique colors in first-seen order, 3 bytes RGB each.
- pixels — each pixel's palette index packed **LSB-first** using
  `max(1, ceil(log2(NN)))` bits, in **row-major** order, **top-left pixel first**.

The official app's `pixelEncode` is native (NDK `.so`, not decompilable); this format is
the documented equivalent from `node-divoom-timebox-evo` (`jimp_overloads.ts`). PNG/JPG
input is rasterized to 16×16 (nearest-neighbor, top-left origin) by
`ImageToPixelFrameConverter` using CoreGraphics — note the `CGBitmapContext` buffer is
**top-left origin** (`buffer[0]` = top-left pixel), so no vertical flip is applied.

## Accepted raw-hex input formats

`AA BB CC`, `0xAA,0xBB,0xCC`, `AA-BB-CC`, `AA:BB:CC`.

## References

- Official Divoom Android app (decompiled, `apk/` — git-ignored, copyrighted).
- `node-divoom-timebox-evo` `PROTOCOL.md`, `src/drawing/jimp_overloads.ts`, `src/messages/message.ts`.
