import SwiftUI

struct ConnectionPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Status")
                            .foregroundStyle(.secondary)
                        Text(appState.connectionStatus)
                    }
                    GridRow {
                        Text("Selected")
                            .foregroundStyle(.secondary)
                        Text(appState.selectedDevice?.name ?? "None")
                    }
                    GridRow {
                        Text("Address")
                            .foregroundStyle(.secondary)
                        Text(appState.selectedDevice?.address ?? "-")
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("RFCOMM")
                            .foregroundStyle(.secondary)
                        Text(appState.lastRFCOMMChannelID.map(String.init) ?? "-")
                    }
                }

                HStack {
                    Button {
                        appState.connect()
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(appState.selectedDevice == nil || appState.isBusy || appState.isConnected)

                    Button {
                        appState.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(!appState.isConnected)

                    Spacer()
                }

                Divider()

                RawHexSenderView()
            }
            .padding(4)
        }
    }
}
