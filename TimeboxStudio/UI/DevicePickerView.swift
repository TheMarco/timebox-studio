import SwiftUI
import TimeboxBluetooth

struct DevicePickerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                Button {
                    appState.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Toggle("Use mock transport", isOn: $appState.useMockTransport)
                .onChange(of: appState.useMockTransport) { _ in
                    appState.disconnect(silent: true)
                    appState.refreshDevices()
                }

            List(selection: $appState.selectedDeviceID) {
                ForEach(appState.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                }
            }
            .listStyle(.sidebar)

            Text("Select the light-side Timebox device, usually named Timebox-evo-light. The audio-side device is not needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct DeviceRow: View {
    let device: TimeboxDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if device.isTimeboxCandidate {
                    Text("Timebox")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if device.isTimeboxAudioSide {
                    Text("Audio")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            Text(device.address)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(device.isPaired ? "Paired" : "Not paired")
                Text(device.isConnected ? "Connected" : "Idle")
                Text(device.source.rawValue)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
