# Development Notes

## Scope

Current milestone implements Phase 1 and Phase 2 only:

- Native SwiftUI app shell
- Transport abstraction
- Mock transport
- IOBluetooth RFCOMM transport
- Paired-device scanner
- CoreBluetooth BLE scanner, GATT inspector, and raw BLE writer
- Raw hex sender
- Brightness packet encoder
- `timeboxctl list`
- `timeboxctl connect`
- `timeboxctl send-hex`
- `timeboxctl brightness`

Pixel editing, image packets, and animation are not implemented yet.

## Protocol Assumptions

The app and CLI generate the first real Timebox Evo packet: brightness.

The brightness encoder is ported from:

- `RomRider/node-divoom-timebox-evo`
- `PROTOCOL.md` in that repository

Packet code should stay inside `TimeboxStudio/TimeboxKit`.

Implemented packet wrapper:

```text
01 LLLL PAYLOAD CRCR 02
```

Brightness payload:

```text
74 BB
```

For `brightness 50`, `BB` is `32`, length is `04 00`, checksum is `AA 00`, and the full packet is:

```text
01 04 00 74 32 AA 00 02
```

## Packet Examples

Raw bytes entered in the app or CLI are parsed with these accepted formats:

```text
AA BB CC
0xAA,0xBB,0xCC
AA-BB-CC
AA:BB:CC
```

The app logs:

- outgoing packet hex
- packet byte count
- transport success/failure

Brightness command logs include:

- command name
- command parameters
- checksum, if applicable
- raw packet hex

## Bluetooth Assumptions

Initial exploration assumed Bluetooth Classic RFCOMM for LED control, but local device discovery shows the LED display-side device advertising over BLE as:

```text
Timebox-Evo-light
```

Observed advertised BLE service:

```text
AF30
```

Observed GATT service after connection:

```text
49535343-FE7D-4AE5-8FA9-9FAFD205E455
```

Likely Transparent UART write characteristic:

```text
49535343-8841-43F4-A8D4-ECBE34729BB3
```

Likely Transparent UART notify/readback characteristic:

```text
49535343-1E4D-4BD9-BA61-23C647249616
```

The audio-side device may appear separately:

```text
Timebox-evo-audio
```

The paired-device scanner lists all paired Classic devices and visually marks names containing `Timebox`.

If the light/control side is paired under an unexpected name, use SDP inspection:

```sh
.build/debug/timeboxctl inspect --address "fa-5e-6f-6e-79-42"
```

Look for services with a non-empty `RFCOMM` channel. Those are the best candidates for raw packet tests.

If SDP inspection hangs or times out, bypass SDP:

```sh
.build/debug/timeboxctl probe-rfcomm --address "fa-5e-6f-6e-79-42"
.build/debug/timeboxctl connect --address "fa-5e-6f-6e-79-42" --channel 1
```

For CLI Bluetooth testing, run the built executable directly:

```sh
.build/debug/timeboxctl list
.build/debug/timeboxctl scan --seconds 12
.build/debug/timeboxctl scan-ble --seconds 12
.build/debug/timeboxctl inspect-ble --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" --service AF30
```

Classic RFCOMM remains in the prototype for exploration, but the real `Timebox-Evo-light` control endpoint seen locally is BLE Transparent UART. Current real-device testing should prioritize:

```sh
.build/debug/timeboxctl inspect-ble --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3"
.build/debug/timeboxctl brightness 50 --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3"
```

In local verification, `swift run timeboxctl list` was terminated before app code received control, while `.build/debug/timeboxctl list` returned normally. This appears to be SwiftPM launch-wrapper interaction with macOS Bluetooth privacy/TCC rather than scanner logic.

## RFCOMM Channel Discovery

`IOBluetoothTimeboxTransport` reads RFCOMM channel IDs from the paired device's SDP service records:

```swift
serviceRecord.getRFCOMMChannelID(&channelID)
```

If no RFCOMM channel is visible through SDP, the transport tries channel `1` as a fallback. The UI and CLI report the channel used when connection succeeds.

Failures include exact `IOReturn` numeric and hex codes. Common causes:

- device is not paired
- device is asleep or out of range
- wrong device selected, for example audio-side device
- macOS denied Bluetooth access
- RFCOMM channel ID is wrong

## Entitlement Note

For a personal prototype, this package is not sandboxed. For later packaging or App Store-style distribution, add the Bluetooth entitlement:

```text
com.apple.security.device.bluetooth
```

## TODO Byte Ranges

These are intentionally unverified until the next protocol ports begin:

- escape/framing bytes
- solid-color command payload
- image payload layout for 16x16 RGB frames
