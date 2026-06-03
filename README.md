# Timebox Studio

Native macOS prototype for controlling a Divoom Timebox Evo 16x16 LED display directly from a Mac.

Phase 1/2 status:

- SwiftUI macOS shell app
- Paired Bluetooth device listing through Apple's `IOBluetooth` framework
- Mock transport for UI development without hardware
- RFCOMM transport implementation for Bluetooth Classic writes
- BLE scan, service inspection, and raw BLE write diagnostics
- Raw hex sender in the app
- Brightness packet encoder with tests
- `timeboxctl list`
- `timeboxctl connect`
- `timeboxctl send-hex`
- `timeboxctl scan-ble`
- `timeboxctl inspect-ble`
- `timeboxctl send-ble-hex`
- `timeboxctl brightness`

Image packets, pixel editing, PNG import/export, and animation are intentionally deferred until later phases.

## Pair Timebox Evo With macOS

The audio-side device may pair in macOS System Settings as something like `Timebox-Evo-audio`, but the LED control endpoint has been observed advertising over BLE as `Timebox-Evo-light`.

For the BLE light endpoint:

1. Turn on the Timebox Evo.
2. Make sure the official Divoom app is not actively connected.
3. Run `scan-ble` and look for `Timebox-Evo-light`.
4. Use the printed BLE UUID with `inspect-ble`, `send-ble-hex`, or `brightness`.

The prototype only controls the LED display side.

If `timeboxctl list` only shows `Timebox-Evo-audio`, macOS has paired the speaker/audio side but not the LED control side. That device is useful as a speaker, but it is not the target for LED packets.

## Build In Xcode

1. Open `TimeboxStudio.xcworkspace` in Xcode.
2. Select the `TimeboxStudio` scheme to run the SwiftUI app.
3. Select the `timeboxctl` scheme to run the command-line helper.

You can also open `Package.swift` directly in Xcode.

## Build From Terminal

```sh
swift build
swift test
```

Run the app from SwiftPM:

```sh
swift run TimeboxStudio
```

Run the CLI:

```sh
swift run timeboxctl list
```

For real Bluetooth access, prefer the built binary after `swift build`:

```sh
.build/debug/timeboxctl list
```

On some macOS setups, launching Bluetooth code through `swift run` can be terminated by privacy/TCC behavior before the CLI receives control. Running the built executable directly avoids that SwiftPM launch wrapper.

## Use Mock Transport

The app starts with mock transport enabled. This shows a virtual `Mock Timebox-evo-light` device and lets you test connection state, raw hex parsing, logging, and packet display without touching Bluetooth hardware.

To test real Bluetooth:

1. Turn off `Use mock transport`.
2. Click `Refresh`.
3. Select the paired Timebox light-side device.
4. Click `Connect`.

## Use timeboxctl

List paired Bluetooth devices:

```sh
.build/debug/timeboxctl list
```

Actively scan nearby Bluetooth Classic devices:

```sh
.build/debug/timeboxctl scan --seconds 12
```

Actively scan nearby Bluetooth LE advertisements:

```sh
.build/debug/timeboxctl scan-ble --seconds 12
```

Inspect BLE services and characteristics:

```sh
.build/debug/timeboxctl inspect-ble --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" --service AF30
```

Send raw bytes over BLE after identifying a writable characteristic:

```sh
.build/debug/timeboxctl send-ble-hex --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3" "AA BB CC"
```

Send a real brightness command over BLE:

```sh
.build/debug/timeboxctl brightness 50 --uuid "BE32D255-6999-AE59-4577-4F5BDA0458D3"
```

For 50%, the generated packet should be:

```text
01 04 00 74 32 AA 00 02
```

Connect to the first paired device whose name contains `Timebox`:

```sh
.build/debug/timeboxctl connect
```

Connect by name:

```sh
.build/debug/timeboxctl connect --name "Timebox-evo-light"
```

Inspect RFCOMM/SDP services by name:

```sh
.build/debug/timeboxctl inspect --name "Timebox-evo-light"
```

Inspect a suspicious paired device by address:

```sh
.build/debug/timeboxctl inspect --address "fa-5e-6f-6e-79-42"
```

If SDP inspection times out, bypass SDP and probe RFCOMM directly:

```sh
.build/debug/timeboxctl probe-rfcomm --address "fa-5e-6f-6e-79-42"
.build/debug/timeboxctl probe-rfcomm --address "f9-ae-e8-b0-37-64"
```

Connect by address:

```sh
.build/debug/timeboxctl connect --address "fa-5e-6f-6e-79-42" --channel 1
```

Send raw hex to the first Timebox candidate:

```sh
.build/debug/timeboxctl send-hex "AA BB CC"
```

Send raw hex by name:

```sh
.build/debug/timeboxctl send-hex --name "Timebox-evo-light" "AA BB CC"
```

Send raw hex by address:

```sh
.build/debug/timeboxctl send-hex --address "fa-5e-6f-6e-79-42" --channel 1 "AA BB CC"
```

Dry-run with the mock transport:

```sh
swift run timeboxctl send-hex --mock "AA BB CC"
```

## Known Issues

- Only the brightness packet is implemented in the real Timebox Evo encoder so far.
- The SwiftUI app still connects through the Phase 1/2 `TimeboxTransport` path. The verified BLE Transparent UART path is currently exposed through `timeboxctl`.
- RFCOMM channel discovery uses paired-device SDP service records and falls back to channel `1` if no RFCOMM service record is visible.
- `timeboxctl scan` can find nearby unpaired Bluetooth Classic devices, but the Timebox must be in a discoverable/pairing state.
- `timeboxctl scan-ble` can find BLE advertisements and is useful if the light/control endpoint is not exposed as Bluetooth Classic.
- `timeboxctl inspect-ble` and `send-ble-hex` are diagnostic tools for the BLE light/control endpoint.
- Some macOS Bluetooth failures may require unpairing and re-pairing the light-side device.
- If `swift run timeboxctl list` exits before output, run `.build/debug/timeboxctl list` directly.
- Swift Package Manager runs the SwiftUI app as an executable prototype. Later distribution can move to a full `.app` bundle project if needed.
- For sandboxed distribution, Apple documents a Bluetooth entitlement named `com.apple.security.device.bluetooth`.

## Next Steps

1. Test `timeboxctl brightness 50 --uuid ...` against the real `Timebox-Evo-light`.
2. Promote the BLE Transparent UART client into a `TimeboxTransport` implementation for the SwiftUI app.
3. Port `PixelFrame` and solid-color/image packet generation.
4. Add the first 16x16 pixel editor once still-image sending is verified.
